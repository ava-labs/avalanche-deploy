package main

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestLoadPrivateKeyNormalizesFlagValue(t *testing.T) {
	t.Helper()

	originalPrivateKey := privateKey
	originalPrivateKeyFile := privateKeyFile
	defer func() {
		privateKey = originalPrivateKey
		privateKeyFile = originalPrivateKeyFile
	}()

	privateKey = "PrivateKey-abcdef"
	privateKeyFile = ""
	t.Setenv("AVALANCHE_PRIVATE_KEY", "")

	got, err := loadPrivateKey()
	if err != nil {
		t.Fatalf("loadPrivateKey returned error: %v", err)
	}
	if got != "0xabcdef" {
		t.Fatalf("unexpected key: got %q want %q", got, "0xabcdef")
	}
}

func TestLoadPrivateKeyFromFile(t *testing.T) {
	t.Helper()

	tmpDir := t.TempDir()
	keyFile := filepath.Join(tmpDir, "key.txt")
	if err := os.WriteFile(keyFile, []byte("abc123\n"), 0o600); err != nil {
		t.Fatalf("failed to write key file: %v", err)
	}

	originalPrivateKey := privateKey
	originalPrivateKeyFile := privateKeyFile
	defer func() {
		privateKey = originalPrivateKey
		privateKeyFile = originalPrivateKeyFile
	}()

	privateKey = ""
	privateKeyFile = keyFile
	t.Setenv("AVALANCHE_PRIVATE_KEY", "")

	got, err := loadPrivateKey()
	if err != nil {
		t.Fatalf("loadPrivateKey returned error: %v", err)
	}
	if got != "0xabc123" {
		t.Fatalf("unexpected key: got %q want %q", got, "0xabc123")
	}
}

func TestLoadPrivateKeyReturnsErrorWhenUnset(t *testing.T) {
	t.Helper()

	originalPrivateKey := privateKey
	originalPrivateKeyFile := privateKeyFile
	defer func() {
		privateKey = originalPrivateKey
		privateKeyFile = originalPrivateKeyFile
	}()

	privateKey = ""
	privateKeyFile = ""
	t.Setenv("AVALANCHE_PRIVATE_KEY", "")

	_, err := loadPrivateKey()
	if err == nil {
		t.Fatal("expected error when private key sources are unset")
	}
}

func TestLoadProxyAdminPrivateKeyUsesSeparateEnvironmentKey(t *testing.T) {
	t.Setenv("GENESIS_PROXY_ADMIN_PRIVATE_KEY", "abc123")

	got, err := loadProxyAdminPrivateKey("0xdefault")
	if err != nil {
		t.Fatalf("loadProxyAdminPrivateKey returned error: %v", err)
	}
	if got != "0xabc123" {
		t.Fatalf("unexpected proxy admin key: got %q want %q", got, "0xabc123")
	}
}

func TestValidateProxyUpgradeAuthority(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("test uses a POSIX shell script")
	}

	const privateKeyHex = "0x0000000000000000000000000000000000000000000000000000000000000001"
	owner, err := getAddressFromPrivateKey(privateKeyHex)
	if err != nil {
		t.Fatalf("derive test owner: %v", err)
	}

	binDir := t.TempDir()
	castPath := filepath.Join(binDir, "cast")
	script := "#!/bin/sh\n" +
		"case \"$1\" in\n" +
		"  storage) echo 0x000000000000000000000000dad0000000000000000000000000000000000000 ;;\n" +
		"  call) echo " + owner + " ;;\n" +
		"  *) exit 1 ;;\n" +
		"esac\n"
	if err := os.WriteFile(castPath, []byte(script), 0o700); err != nil {
		t.Fatalf("write fake cast: %v", err)
	}
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	err = validateProxyUpgradeAuthority(
		context.Background(),
		"http://rpc.invalid",
		"0xfacade0000000000000000000000000000000000",
		privateKeyHex,
	)
	if err != nil {
		t.Fatalf("validateProxyUpgradeAuthority returned error: %v", err)
	}
}

func TestValidateProxyUpgradeAuthorityRejectsWrongKey(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("test uses a POSIX shell script")
	}

	binDir := t.TempDir()
	castPath := filepath.Join(binDir, "cast")
	script := "#!/bin/sh\n" +
		"case \"$1\" in\n" +
		"  storage) echo 0x000000000000000000000000dad0000000000000000000000000000000000000 ;;\n" +
		"  call) echo 0x0000000000000000000000000000000000000002 ;;\n" +
		"  *) exit 1 ;;\n" +
		"esac\n"
	if err := os.WriteFile(castPath, []byte(script), 0o700); err != nil {
		t.Fatalf("write fake cast: %v", err)
	}
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	err := validateProxyUpgradeAuthority(
		context.Background(),
		"http://rpc.invalid",
		"0xfacade0000000000000000000000000000000000",
		"0x0000000000000000000000000000000000000000000000000000000000000001",
	)
	if err == nil {
		t.Fatal("expected a proxy admin owner mismatch")
	}
}

func TestDeployImplementationRejectsUnknownManager(t *testing.T) {
	t.Helper()

	_, _, err := deployImplementation(context.Background(), "", "", "", "unknown", "")
	if err == nil {
		t.Fatal("expected error for unknown manager type")
	}
}

func TestParseForgeCreateOutput(t *testing.T) {
	t.Parallel()

	const deployedTo = "0x13f082a4480E30381026eacdb98bC4CD84183035"
	tests := []struct {
		name   string
		output string
	}{
		{
			name:   "plain JSON",
			output: `{"deployer":"0xabc","deployedTo":"` + deployedTo + `","transactionHash":"0xdef"}`,
		},
		{
			name: "Foundry warnings before JSON",
			output: "Warning: Found unknown `number_underscores` config key in section `fmt` defined in foundry.toml.\n" +
				"Warning: another warning.\n" +
				`{"deployer":"0xabc","deployedTo":"` + deployedTo + `","transactionHash":"0xdef"}` + "\n",
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			got, err := parseForgeCreateOutput([]byte(tt.output))
			if err != nil {
				t.Fatalf("parseForgeCreateOutput returned error: %v", err)
			}
			if got != deployedTo {
				t.Fatalf("unexpected deployed address: got %q want %q", got, deployedTo)
			}
		})
	}
}

func TestParseForgeCreateOutputRejectsMissingAddress(t *testing.T) {
	t.Parallel()

	_, err := parseForgeCreateOutput([]byte("Warning: config key is unknown\n{\"transactionHash\":\"0xdef\"}\n"))
	if err == nil {
		t.Fatal("expected an error when deployedTo is missing")
	}
}
