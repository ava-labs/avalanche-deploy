package main

import (
	"context"
	"os"
	"path/filepath"
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

func TestDeployImplementationRejectsUnknownManager(t *testing.T) {
	t.Helper()

	_, _, err := deployImplementation(context.Background(), "", "", "", "unknown")
	if err == nil {
		t.Fatal("expected error for unknown manager type")
	}
}
