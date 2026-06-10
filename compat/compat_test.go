// Copyright (C) 2024, Ava Labs, Inc. All rights reserved.
// See the file LICENSE for licensing terms.

// Package compat cross-checks remote-signer's BLS signing against AvalancheGo
// itself. A signature produced by this sidecar MUST be indistinguishable from
// one produced by AvalancheGo's local signer with the same key — otherwise
// every warp/ICM message the validator signs is silently rejected by the
// network while proofs of possession (and therefore registration) still work.
//
// This module exists because exactly that happened: Sign() used the IETF
// basic-scheme DST (...RO_NUL_) instead of AvalancheGo's proof-of-possession
// scheme DST (...RO_POP_), and nothing caught it until signatures failed
// on-network. These tests pin the constants and the end-to-end behavior
// against the real avalanchego bls package.
package compat

import (
	"crypto/rand"
	"testing"

	avabls "github.com/ava-labs/avalanchego/utils/crypto/bls"

	"github.com/ava-labs/avalanche-remote-signer/internal/blstutil"
)

// TestDSTsMatchAvalancheGo pins our DST constants to AvalancheGo's
// ciphersuites byte-for-byte.
func TestDSTsMatchAvalancheGo(t *testing.T) {
	if got, want := string(blstutil.DSTSign), avabls.CiphersuiteSignature.String(); got != want {
		t.Errorf("DSTSign = %q, avalanchego CiphersuiteSignature = %q", got, want)
	}
	if got, want := string(blstutil.DSTPoP), avabls.CiphersuiteProofOfPossession.String(); got != want {
		t.Errorf("DSTPoP = %q, avalanchego CiphersuiteProofOfPossession = %q", got, want)
	}
}

// TestSignaturesVerifyUnderAvalancheGo signs with remote-signer's signing core
// and verifies with AvalancheGo, both positive and cross-negative.
func TestSignaturesVerifyUnderAvalancheGo(t *testing.T) {
	ikm := make([]byte, 32)
	if _, err := rand.Read(ikm); err != nil {
		t.Fatal(err)
	}
	skBytes, err := blstutil.KeyGen(ikm)
	if err != nil {
		t.Fatal(err)
	}
	pkBytes, err := blstutil.PublicKey(skBytes)
	if err != nil {
		t.Fatal(err)
	}
	pk, err := avabls.PublicKeyFromCompressedBytes(pkBytes)
	if err != nil {
		t.Fatalf("avalanchego rejected our public key: %v", err)
	}

	msg := []byte("remote-signer/avalanchego BLS compatibility test")

	sigBytes, err := blstutil.Sign(skBytes, msg, blstutil.DSTSign)
	if err != nil {
		t.Fatal(err)
	}
	sig, err := avabls.SignatureFromBytes(sigBytes)
	if err != nil {
		t.Fatalf("avalanchego rejected our signature encoding: %v", err)
	}
	if !avabls.Verify(pk, sig, msg) {
		t.Error("Sign output does NOT verify as an avalanchego message signature — warp/ICM would reject every signature")
	}
	if avabls.VerifyProofOfPossession(pk, sig, msg) {
		t.Error("Sign output unexpectedly verifies as a proof of possession — DSTs are crossed")
	}

	popBytes, err := blstutil.Sign(skBytes, msg, blstutil.DSTPoP)
	if err != nil {
		t.Fatal(err)
	}
	pop, err := avabls.SignatureFromBytes(popBytes)
	if err != nil {
		t.Fatal(err)
	}
	if !avabls.VerifyProofOfPossession(pk, pop, msg) {
		t.Error("PoP output does NOT verify as an avalanchego proof of possession — validator registration would fail")
	}
	if avabls.Verify(pk, pop, msg) {
		t.Error("PoP output unexpectedly verifies as a message signature — DSTs are crossed")
	}
}
