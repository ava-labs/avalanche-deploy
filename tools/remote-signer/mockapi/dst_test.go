// Copyright (C) 2024, Ava Labs, Inc. All rights reserved.
// See the file LICENSE for licensing terms.

// Internal test (package mockapi) so it can read the unexported key and verify
// that Sign uses the Warp DST and SignProofOfPossession the PoP DST. A swap
// passes the length checks in memory_test.go but is silently rejected
// on-network — the historical RO_NUL_/RO_POP_ failure.
package mockapi

import (
	"bytes"
	"context"
	"testing"

	"github.com/ava-labs/avalanche-deploy/tools/remote-signer/internal/blstutil"
)

func TestSignUsesCorrectDSTs(t *testing.T) {
	b, err := New()
	if err != nil {
		t.Fatal(err)
	}
	defer b.Close() // zeroes skBytes; runs after the assertions below

	msg := []byte("hello warp")
	sig, err := b.Sign(context.Background(), msg)
	if err != nil {
		t.Fatal(err)
	}
	pop, err := b.SignProofOfPossession(context.Background(), msg)
	if err != nil {
		t.Fatal(err)
	}

	// BLS signing is deterministic — reconstruct the expected outputs from the
	// backend's own key under each DST and compare byte-for-byte.
	if want, _ := blstutil.Sign(b.skBytes, msg, blstutil.DSTSign); !bytes.Equal(sig, want) {
		t.Error("Sign did not use the Warp DST (blstutil.DSTSign)")
	}
	if want, _ := blstutil.Sign(b.skBytes, msg, blstutil.DSTPoP); !bytes.Equal(pop, want) {
		t.Error("SignProofOfPossession did not use the PoP DST (blstutil.DSTPoP)")
	}
	if bytes.Equal(sig, pop) {
		t.Error("Sign and SignProofOfPossession produced identical bytes — DSTs not differentiated")
	}
}
