// Copyright (C) 2024, Ava Labs, Inc. All rights reserved.
// See the file LICENSE for licensing terms.

// Package blstutil wraps github.com/supranational/blst/bindings/go with a
// pure-Go API that matches the blstcgo package it replaces.  All functions
// take and return plain []byte — no CGO types are exposed to callers.
package blstutil

import (
	"fmt"

	blst "github.com/supranational/blst/bindings/go"
)

const (
	SecretKeySize = 32
	PublicKeySize = 48
	SignatureSize = 96
)

// Domain separation tags used by AvalancheGo, which implements the IETF BLS
// proof-of-possession scheme (see avalanchego utils/crypto/bls/ciphersuite.go).
// Warp/ICM message signatures use DSTSign; proofs of possession use DSTPoP.
// Note the message-signing DST ends in POP_ (the scheme tag), NOT NUL_ —
// NUL_ is the basic scheme and its signatures are rejected by every Avalanche
// warp verifier. These constants are cross-checked against AvalancheGo by the
// tests/ module.
var (
	DSTSign = []byte("BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_")
	DSTPoP  = []byte("BLS_POP_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_")
)

// Every function below deterministically zeroizes its transient
// blst.SecretKey before returning.  blst only arranges zeroing for KeyGen'd
// keys, via a GC finalizer — Deserialize'd keys get nothing, and (as blst's
// own comment puts it) "postponing secret key zeroing till garbage collection
// can be too late to be effective".  Without this, every Sign call would leave
// an uncleared copy of the scalar in freed heap memory.  This is hardening
// against opportunistic memory disclosure (core dumps, swap), not protection
// from a live memory-read attacker — for that, use the aws-nitro backend.

// KeyGen derives a valid BLS12-381 secret key from input key material (IKM)
// using the standard HKDF-based derivation.  IKM must be at least 32 bytes.
func KeyGen(ikm []byte) ([]byte, error) {
	if len(ikm) < 32 {
		return nil, fmt.Errorf("IKM must be at least 32 bytes, got %d", len(ikm))
	}
	sk := blst.KeyGen(ikm)
	if sk == nil {
		return nil, fmt.Errorf("BLS key generation failed")
	}
	defer sk.Zeroize()
	return sk.Serialize(), nil
}

// ValidateSecretKey returns true if skBytes is a valid 32-byte BLS12-381
// secret key scalar (non-zero and less than the curve order).
func ValidateSecretKey(skBytes []byte) bool {
	if len(skBytes) != SecretKeySize {
		return false
	}
	sk := new(blst.SecretKey)
	if sk.Deserialize(skBytes) == nil {
		return false
	}
	sk.Zeroize()
	return true
}

// PublicKey derives the 48-byte compressed G1 public key from skBytes.
func PublicKey(skBytes []byte) ([]byte, error) {
	sk, err := deserialize(skBytes)
	if err != nil {
		return nil, err
	}
	defer sk.Zeroize()
	pk := new(blst.P1Affine).From(sk)
	if pk == nil {
		return nil, fmt.Errorf("BLS public key derivation failed")
	}
	return pk.Compress(), nil
}

// Sign hashes msg to G2 with the given DST and signs it with skBytes,
// returning a 96-byte compressed G2 signature.
func Sign(skBytes, msg, dst []byte) ([]byte, error) {
	sk, err := deserialize(skBytes)
	if err != nil {
		return nil, err
	}
	defer sk.Zeroize()
	sig := new(blst.P2Affine).Sign(sk, msg, dst)
	if sig == nil {
		return nil, fmt.Errorf("BLS sign failed")
	}
	return sig.Compress(), nil
}

func deserialize(skBytes []byte) (*blst.SecretKey, error) {
	if len(skBytes) != SecretKeySize {
		return nil, fmt.Errorf("expected %d-byte secret key, got %d", SecretKeySize, len(skBytes))
	}
	sk := new(blst.SecretKey)
	if sk.Deserialize(skBytes) == nil {
		return nil, fmt.Errorf("invalid BLS key material — not a valid scalar")
	}
	return sk, nil
}
