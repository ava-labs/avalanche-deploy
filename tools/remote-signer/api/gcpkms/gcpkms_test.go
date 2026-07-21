// Copyright (C) 2024, Ava Labs, Inc. All rights reserved.
// See the file LICENSE for licensing terms.

package gcpkms

import (
	"bytes"
	"context"
	"crypto/rand"
	"os"
	"testing"

	kmspb "cloud.google.com/go/kms/apiv1/kmspb"
	gax "github.com/googleapis/gax-go/v2"

	signerconfig "github.com/ava-labs/avalanche-remote-signer/config"
	"github.com/ava-labs/avalanche-remote-signer/internal/blstutil"
)

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

func (m *mockKMS) Decrypt(_ context.Context, req *kmspb.DecryptRequest, _ ...gax.CallOption) (*kmspb.DecryptResponse, error) {
	return &kmspb.DecryptResponse{Plaintext: m.xor(req.Ciphertext)}, nil
}

func (m *mockKMS) Encrypt(_ context.Context, req *kmspb.EncryptRequest, _ ...gax.CallOption) (*kmspb.EncryptResponse, error) {
	return &kmspb.EncryptResponse{Ciphertext: m.xor(req.Plaintext)}, nil
}

func (m *mockKMS) Close() error { return nil }

func TestRoundTrip(t *testing.T) {
	var ikm [32]byte
	if _, err := rand.Read(ikm[:]); err != nil {
		t.Fatal(err)
	}
	skBytes, err := blstutil.KeyGen(ikm[:])
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

	cfg := signerconfig.GCPConfig{
		Project: "p", Location: "l", KeyRing: "r", KeyName: "k",
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

	// Sign must use the Warp DST and PoP the PoP DST. A swap passes the length
	// checks but is rejected on-network (the historical RO_NUL_/RO_POP_ bug).
	// BLS signing is deterministic — reconstruct from the known key.
	if want, _ := blstutil.Sign(skBytes, msg, blstutil.DSTSign); !bytes.Equal(sig, want) {
		t.Error("Sign did not use the Warp DST (blstutil.DSTSign)")
	}
	if want, _ := blstutil.Sign(skBytes, msg, blstutil.DSTPoP); !bytes.Equal(popSig, want) {
		t.Error("SignProofOfPossession did not use the PoP DST (blstutil.DSTPoP)")
	}
	if bytes.Equal(sig, popSig) {
		t.Error("Sign and SignProofOfPossession produced identical bytes — DSTs not differentiated")
	}
}

func TestIntegration_GCPKMS(t *testing.T) {
	project := os.Getenv("GCP_PROJECT")
	location := os.Getenv("GCP_LOCATION")
	keyRing := os.Getenv("GCP_KEY_RING")
	keyName := os.Getenv("GCP_KEY_NAME")
	keyPath := os.Getenv("GCP_ENCRYPTED_BLS_KEY_PATH")
	if project == "" || location == "" || keyRing == "" || keyName == "" || keyPath == "" {
		t.Skip("set GCP_PROJECT, GCP_LOCATION, GCP_KEY_RING, GCP_KEY_NAME, GCP_ENCRYPTED_BLS_KEY_PATH to run")
	}

	cfg := signerconfig.GCPConfig{
		Project: project, Location: location, KeyRing: keyRing, KeyName: keyName,
		EncryptedBLSKeyPath: keyPath,
	}
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
