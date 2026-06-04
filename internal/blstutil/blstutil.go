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
	return sk.Serialize(), nil
}

// ValidateSecretKey returns true if skBytes is a valid 32-byte BLS12-381
// secret key scalar (non-zero and less than the curve order).
func ValidateSecretKey(skBytes []byte) bool {
	if len(skBytes) != SecretKeySize {
		return false
	}
	sk := new(blst.SecretKey)
	return sk.Deserialize(skBytes) != nil
}

// PublicKey derives the 48-byte compressed G1 public key from skBytes.
func PublicKey(skBytes []byte) ([]byte, error) {
	sk, err := deserialize(skBytes)
	if err != nil {
		return nil, err
	}
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
