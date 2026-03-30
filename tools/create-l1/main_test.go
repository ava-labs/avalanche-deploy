package main

import (
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ava-labs/avalanchego/ids"
	"github.com/ava-labs/avalanchego/utils/crypto/secp256k1"
	pkgkeystore "github.com/ava-labs/platform-cli/pkg/keystore"
)

func TestDeriveEthAddressEwoq(t *testing.T) {
	t.Helper()

	// Known key used in many Avalanche test flows.
	keyBytes, err := hex.DecodeString("56289e99c94b6912bfc12adc093c9b51124f0dc54ac7a766b2bc5ccf558d8027")
	if err != nil {
		t.Fatalf("failed to decode key: %v", err)
	}
	key, err := secp256k1.ToPrivateKey(keyBytes)
	if err != nil {
		t.Fatalf("failed to parse key: %v", err)
	}

	got := deriveEthAddress(key)
	want := "0x8db97c7cece249c2b98bdc0226cc4c2a57bf52fc"
	if got != want {
		t.Fatalf("unexpected ETH address: got %s want %s", got, want)
	}
}

func TestExtractEVMChainID(t *testing.T) {
	t.Helper()

	tests := []struct {
		name    string
		genesis string
		want    string
	}{
		{
			name:    "numeric chain id",
			genesis: `{"config":{"chainId":99999}}`,
			want:    "99999",
		},
		{
			name:    "string chain id",
			genesis: `{"config":{"chainId":"43114"}}`,
			want:    "43114",
		},
		{
			name:    "missing chain id",
			genesis: `{"config":{"foo":"bar"}}`,
			want:    "",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := extractEVMChainID([]byte(tc.genesis))
			if got != tc.want {
				t.Fatalf("unexpected chain id: got %q want %q", got, tc.want)
			}
		})
	}
}

func TestCheckGenesisFunding(t *testing.T) {
	t.Helper()

	genesis := []byte(`{
	  "alloc": {
	    "0xabc1230000000000000000000000000000000000": { "balance": "0xde0b6b3a7640000" }
	  }
	}`)

	funded, balance := checkGenesisFunding(genesis, "0xAbC1230000000000000000000000000000000000")
	if !funded {
		t.Fatalf("expected address to be funded")
	}
	if balance != "0xde0b6b3a7640000" {
		t.Fatalf("unexpected balance: %s", balance)
	}
}

func TestFindGenesisFilePrefersConfigsPath(t *testing.T) {
	t.Helper()

	tmpDir := t.TempDir()
	genesisDir := filepath.Join(tmpDir, "configs", "l1", "genesis")
	if err := os.MkdirAll(genesisDir, 0o755); err != nil {
		t.Fatalf("failed to create genesis dir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(genesisDir, "genesis.json"), []byte(`{"config":{"chainId":1}}`), 0o644); err != nil {
		t.Fatalf("failed to write config genesis: %v", err)
	}
	if err := os.WriteFile(filepath.Join(tmpDir, "genesis.json"), []byte(`{"config":{"chainId":2}}`), 0o644); err != nil {
		t.Fatalf("failed to write fallback genesis: %v", err)
	}

	originalWD, err := os.Getwd()
	if err != nil {
		t.Fatalf("failed to get current dir: %v", err)
	}
	defer func() {
		if chdirErr := os.Chdir(originalWD); chdirErr != nil {
			t.Fatalf("failed to restore working dir: %v", chdirErr)
		}
	}()
	if err := os.Chdir(tmpDir); err != nil {
		t.Fatalf("failed to change dir: %v", err)
	}

	got, err := findGenesisFile()
	if err != nil {
		t.Fatalf("findGenesisFile returned error: %v", err)
	}
	want := filepath.Join(tmpDir, "configs", "l1", "genesis", "genesis.json")
	assertSameFile(t, got, want)
}

func TestFindGenesisFileFindsParentConfigsPath(t *testing.T) {
	t.Helper()

	tmpDir := t.TempDir()
	genesisDir := filepath.Join(tmpDir, "configs", "l1", "genesis")
	if err := os.MkdirAll(genesisDir, 0o755); err != nil {
		t.Fatalf("failed to create genesis dir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(genesisDir, "genesis.json"), []byte(`{"config":{"chainId":99999}}`), 0o644); err != nil {
		t.Fatalf("failed to write genesis file: %v", err)
	}

	nestedDir := filepath.Join(tmpDir, "tools", "create-l1")
	if err := os.MkdirAll(nestedDir, 0o755); err != nil {
		t.Fatalf("failed to create nested dir: %v", err)
	}

	originalWD, err := os.Getwd()
	if err != nil {
		t.Fatalf("failed to get current dir: %v", err)
	}
	defer func() {
		if chdirErr := os.Chdir(originalWD); chdirErr != nil {
			t.Fatalf("failed to restore working dir: %v", chdirErr)
		}
	}()
	if err := os.Chdir(nestedDir); err != nil {
		t.Fatalf("failed to change dir: %v", err)
	}

	got, err := findGenesisFile()
	if err != nil {
		t.Fatalf("findGenesisFile returned error: %v", err)
	}
	want := filepath.Join(tmpDir, "configs", "l1", "genesis", "genesis.json")
	assertSameFile(t, got, want)
}

func assertSameFile(t *testing.T, gotPath, wantPath string) {
	t.Helper()

	gotInfo, err := os.Stat(gotPath)
	if err != nil {
		t.Fatalf("failed to stat got path %q: %v", gotPath, err)
	}
	wantInfo, err := os.Stat(wantPath)
	if err != nil {
		t.Fatalf("failed to stat want path %q: %v", wantPath, err)
	}
	if !os.SameFile(gotInfo, wantInfo) {
		t.Fatalf("paths do not reference the same file: got %q want %q", gotPath, wantPath)
	}
}

func TestLoadPrivateKeyFromKeystoreByName(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	ks, err := pkgkeystore.Load()
	if err != nil {
		t.Fatalf("pkgkeystore.Load() error = %v", err)
	}

	keyBytes, err := hex.DecodeString("56289e99c94b6912bfc12adc093c9b51124f0dc54ac7a766b2bc5ccf558d8027")
	if err != nil {
		t.Fatalf("hex.DecodeString() error = %v", err)
	}
	if err := ks.ImportKey("deployer", keyBytes, nil); err != nil {
		t.Fatalf("ks.ImportKey() error = %v", err)
	}

	origKeyName := keyName
	defer func() {
		keyName = origKeyName
	}()

	keyName = "deployer"

	got, err := loadPrivateKey()
	if err != nil {
		t.Fatalf("loadPrivateKey() error = %v", err)
	}

	want, err := secp256k1.ToPrivateKey(keyBytes)
	if err != nil {
		t.Fatalf("secp256k1.ToPrivateKey() error = %v", err)
	}
	if got.Address() != want.Address() {
		t.Fatalf("loadPrivateKey() address = %s, want %s", got.Address(), want.Address())
	}
}

func TestLoadPrivateKeyPrefersEnvOverDefaultKeystore(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	ks, err := pkgkeystore.Load()
	if err != nil {
		t.Fatalf("pkgkeystore.Load() error = %v", err)
	}

	defaultKeyBytes, err := hex.DecodeString("56289e99c94b6912bfc12adc093c9b51124f0dc54ac7a766b2bc5ccf558d8027")
	if err != nil {
		t.Fatalf("hex.DecodeString(default) error = %v", err)
	}
	if err := ks.ImportKey("default", defaultKeyBytes, nil); err != nil {
		t.Fatalf("ks.ImportKey(default) error = %v", err)
	}
	if err := ks.SetDefault("default"); err != nil {
		t.Fatalf("ks.SetDefault() error = %v", err)
	}

	envKeyHex := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	t.Setenv("AVALANCHE_PRIVATE_KEY", "0x"+envKeyHex)

	origKeyName := keyName
	defer func() {
		keyName = origKeyName
	}()

	keyName = ""

	got, err := loadPrivateKey()
	if err != nil {
		t.Fatalf("loadPrivateKey() error = %v", err)
	}

	envKeyBytes, err := hex.DecodeString(envKeyHex)
	if err != nil {
		t.Fatalf("hex.DecodeString(env) error = %v", err)
	}
	want, err := secp256k1.ToPrivateKey(envKeyBytes)
	if err != nil {
		t.Fatalf("secp256k1.ToPrivateKey(env) error = %v", err)
	}
	if got.Address() != want.Address() {
		t.Fatalf("loadPrivateKey() address = %s, want env key address %s", got.Address(), want.Address())
	}
}

func TestBuildNodeURI(t *testing.T) {
	tests := []struct {
		name     string
		endpoint string
		want     string
	}{
		{
			name:     "host only",
			endpoint: "10.0.0.5",
			want:     "http://10.0.0.5:9650",
		},
		{
			name:     "host and port",
			endpoint: "127.0.0.1:19650",
			want:     "http://127.0.0.1:19650",
		},
		{
			name:     "uri passthrough",
			endpoint: "https://example.com:9650",
			want:     "https://example.com:9650",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := buildNodeURI(tc.endpoint)
			if err != nil {
				t.Fatalf("buildNodeURI() error = %v", err)
			}
			if got != tc.want {
				t.Fatalf("buildNodeURI() = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestBuildRPCEndpointsUsesNodeURIs(t *testing.T) {
	nodeURIs := []string{
		"http://127.0.0.1:19650",
		"http://127.0.0.1:19651",
	}
	got := buildRPCEndpoints(nodeURIs, mustID("2ZF68ComC4sqLu7Bwo4sY5rAbd6D3vvwN2NVFKejtVDkRKE2oc"))

	if !strings.Contains(got, "RPC_1_URL=http://127.0.0.1:19650/ext/bc/2ZF68ComC4sqLu7Bwo4sY5rAbd6D3vvwN2NVFKejtVDkRKE2oc/rpc") {
		t.Fatalf("buildRPCEndpoints() missing expected first endpoint: %s", got)
	}
	if !strings.Contains(got, "RPC_2_URL=http://127.0.0.1:19651/ext/bc/2ZF68ComC4sqLu7Bwo4sY5rAbd6D3vvwN2NVFKejtVDkRKE2oc/rpc") {
		t.Fatalf("buildRPCEndpoints() missing expected second endpoint: %s", got)
	}
}

func mustID(s string) ids.ID {
	id, err := ids.FromString(s)
	if err != nil {
		panic(err)
	}
	return id
}
