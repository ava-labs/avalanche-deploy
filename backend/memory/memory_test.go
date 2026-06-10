// Copyright (C) 2024, Ava Labs, Inc. All rights reserved.
// See the file LICENSE for licensing terms.

package memory_test

import (
	"context"
	"testing"

	"github.com/ava-labs/avalanche-remote-signer/backend/memory"
)

func TestNew(t *testing.T) {
	b, err := memory.New()
	if err != nil {
		t.Fatalf("New() error: %v", err)
	}
	defer b.Close()

	ctx := context.Background()

	pk, err := b.PublicKey(ctx)
	if err != nil {
		t.Fatalf("PublicKey() error: %v", err)
	}
	// BLS12-381 compressed public key is always 48 bytes.
	if len(pk) != 48 {
		t.Errorf("PublicKey() len = %d, want 48", len(pk))
	}

	msg := []byte("test message")

	sig, err := b.Sign(ctx, msg)
	if err != nil {
		t.Fatalf("Sign() error: %v", err)
	}
	// BLS12-381 compressed G2 signature is always 96 bytes.
	if len(sig) != 96 {
		t.Errorf("Sign() len = %d, want 96", len(sig))
	}

	pop, err := b.SignProofOfPossession(ctx, msg)
	if err != nil {
		t.Fatalf("SignProofOfPossession() error: %v", err)
	}
	if len(pop) != 96 {
		t.Errorf("SignProofOfPossession() len = %d, want 96", len(pop))
	}

	// Ensure Sign and SignProofOfPossession produce different bytes for the
	// same message (they use different DSTs).
	if string(sig) == string(pop) {
		t.Error("Sign() and SignProofOfPossession() returned identical bytes — DST mismatch?")
	}
}

func TestTwoInstancesHaveDifferentKeys(t *testing.T) {
	a, err := memory.New()
	if err != nil {
		t.Fatal(err)
	}
	b, err := memory.New()
	if err != nil {
		t.Fatal(err)
	}

	ctx := context.Background()
	pkA, _ := a.PublicKey(ctx)
	pkB, _ := b.PublicKey(ctx)

	if string(pkA) == string(pkB) {
		t.Error("two New() calls produced the same key — RNG is broken")
	}
}
