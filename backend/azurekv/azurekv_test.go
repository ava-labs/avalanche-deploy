// Copyright (C) 2024, Ava Labs, Inc. All rights reserved.
// See the file LICENSE for licensing terms.

package azurekv

import (
	"context"
	"crypto/rand"
	"os"
	"testing"

	"github.com/Azure/azure-sdk-for-go/sdk/security/keyvault/azkeys"

	signerconfig "github.com/ava-labs/avalanche-remote-signer/config"
	"github.com/ava-labs/avalanche-remote-signer/internal/blstutil"
)

type mockKV struct{ key [32]byte }

func newMockKV() *mockKV {
	m := &mockKV{}
	if _, err := rand.Read(m.key[:]); err != nil {
		panic(err)
	}
	return m
}

func (m *mockKV) xor(in []byte) []byte {
	out := make([]byte, len(in))
	for i := range in {
		out[i] = in[i] ^ m.key[i%32]
	}
	return out
}

func (m *mockKV) Decrypt(_ context.Context, _, _ string, params azkeys.KeyOperationParameters, _ *azkeys.DecryptOptions) (azkeys.DecryptResponse, error) {
	return azkeys.DecryptResponse{
		KeyOperationResult: azkeys.KeyOperationResult{Result: m.xor(params.Value)},
	}, nil
}

func (m *mockKV) Encrypt(_ context.Context, _, _ string, params azkeys.KeyOperationParameters, _ *azkeys.EncryptOptions) (azkeys.EncryptResponse, error) {
	return azkeys.EncryptResponse{
		KeyOperationResult: azkeys.KeyOperationResult{Result: m.xor(params.Value)},
	}, nil
}

func TestRoundTrip(t *testing.T) {
	var ikm [32]byte
	if _, err := rand.Read(ikm[:]); err != nil {
		t.Fatal(err)
	}
	skBytes, err := blstutil.KeyGen(ikm[:])
	if err != nil {
		t.Fatalf("KeyGen: %v", err)
	}

	mock := newMockKV()
	ciphertext := mock.xor(skBytes)

	f, err := os.CreateTemp(t.TempDir(), "bls-*.key.enc")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.Write(ciphertext); err != nil {
		t.Fatal(err)
	}
	f.Close()

	cfg := signerconfig.AzureConfig{
		VaultURL: "https://my-vault.vault.azure.net/", KeyName: "k",
		EncryptedBLSKeyPath: f.Name(),
	}

	b, err := newWithClient(cfg, nil, mock)
	if err != nil {
		t.Fatalf("newWithClient: %v", err)
	}
	defer b.Close()

	pk, err := b.PublicKey(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(pk) != 48 {
		t.Errorf("expected 48-byte public key, got %d", len(pk))
	}

	sig, err := b.Sign(context.Background(), []byte("hello warp"))
	if err != nil {
		t.Fatal(err)
	}
	if len(sig) != 96 {
		t.Errorf("expected 96-byte signature, got %d", len(sig))
	}
}

func TestIntegration_AzureKV(t *testing.T) {
	vaultURL := os.Getenv("AZURE_VAULT_URL")
	keyName := os.Getenv("AZURE_KEY_NAME")
	keyPath := os.Getenv("AZURE_ENCRYPTED_BLS_KEY_PATH")
	if vaultURL == "" || keyName == "" || keyPath == "" {
		t.Skip("set AZURE_VAULT_URL, AZURE_KEY_NAME, AZURE_ENCRYPTED_BLS_KEY_PATH to run")
	}

	cfg := signerconfig.AzureConfig{VaultURL: vaultURL, KeyName: keyName, EncryptedBLSKeyPath: keyPath}
	b, err := New(cfg, nil)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	defer b.Close()

	pk, err := b.PublicKey(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("public key: %d bytes", len(pk))
}
