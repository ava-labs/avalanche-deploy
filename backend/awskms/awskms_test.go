// Copyright (C) 2024, Ava Labs, Inc. All rights reserved.
// See the file LICENSE for licensing terms.

package awskms

import (
	"context"
	"crypto/rand"
	"os"
	"testing"

	"github.com/aws/aws-sdk-go-v2/service/kms"

	signerconfig "github.com/ava-labs/avalanche-kms-signer/config"
	"github.com/ava-labs/avalanche-kms-signer/internal/blstcgo"
)

// mockKMS applies XOR "encryption" for unit tests only — not cryptographically secure.
type mockKMS struct{ key [32]byte }

func newMockKMS() *mockKMS {
	m := &mockKMS{}
	if _, err := rand.Read(m.key[:]); err != nil {
		panic(err)
	}
	return m
}

func (m *mockKMS) xor(in []byte) []byte {
	out := make([]byte, len(in))
	for i := range in {
		out[i] = in[i] ^ m.key[i%32]
	}
	return out
}

func (m *mockKMS) Decrypt(_ context.Context, in *kms.DecryptInput, _ ...func(*kms.Options)) (*kms.DecryptOutput, error) {
	return &kms.DecryptOutput{Plaintext: m.xor(in.CiphertextBlob)}, nil
}

func (m *mockKMS) Encrypt(_ context.Context, in *kms.EncryptInput, _ ...func(*kms.Options)) (*kms.EncryptOutput, error) {
	return &kms.EncryptOutput{CiphertextBlob: m.xor(in.Plaintext)}, nil
}

func TestRoundTrip(t *testing.T) {
	// Generate a valid BLS key via proper HKDF derivation.
	var ikm [32]byte
	if _, err := rand.Read(ikm[:]); err != nil {
		t.Fatal(err)
	}
	skBytes, err := blstcgo.KeyGen(ikm[:])
	if err != nil {
		t.Fatalf("KeyGen: %v", err)
	}

	mock := newMockKMS()
	ciphertext := mock.xor(skBytes)

	f, err := os.CreateTemp(t.TempDir(), "bls-*.key.enc")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.Write(ciphertext); err != nil {
		t.Fatal(err)
	}
	f.Close()

	cfg := signerconfig.AWSConfig{
		Region:              "us-east-1",
		KMSKeyID:            "fake-key-id",
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

	msg := []byte("hello warp")
	sig, err := b.Sign(context.Background(), msg)
	if err != nil {
		t.Fatal(err)
	}
	if len(sig) != 96 {
		t.Errorf("expected 96-byte signature, got %d", len(sig))
	}

	popSig, err := b.SignProofOfPossession(context.Background(), msg)
	if err != nil {
		t.Fatal(err)
	}
	if len(popSig) != 96 {
		t.Errorf("expected 96-byte PoP signature, got %d", len(popSig))
	}
}

func TestIntegration_AWSKMS(t *testing.T) {
	keyID := os.Getenv("AWS_KMS_KEY_ID")
	region := os.Getenv("AWS_REGION")
	keyPath := os.Getenv("AWS_ENCRYPTED_BLS_KEY_PATH")
	if keyID == "" || region == "" || keyPath == "" {
		t.Skip("set AWS_KMS_KEY_ID, AWS_REGION, AWS_ENCRYPTED_BLS_KEY_PATH to run integration test")
	}

	cfg := signerconfig.AWSConfig{Region: region, KMSKeyID: keyID, EncryptedBLSKeyPath: keyPath}
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
