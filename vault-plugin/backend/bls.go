// Copyright (C) 2024, Ava Labs, Inc. All rights reserved.
// See the file LICENSE for licensing terms.

// BLS12-381 operations for the Vault plugin, using the official blst Go bindings.
package backend

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"

	blst "github.com/supranational/blst/bindings/go"
)

func randRead(b []byte) (int, error) { return rand.Read(b) }

// Every function below deterministically zeroizes its transient
// blst.SecretKey before returning — blst only zeroes KeyGen'd keys, via a GC
// finalizer, and a finalizer can run arbitrarily late.  Without this, every
// sign request would leave an uncleared copy of the scalar in freed heap
// memory of the Vault plugin process.  Hardening against opportunistic
// memory disclosure (core dumps, swap), not a live memory-read attacker.

func generateKey() (string, error) {
	var ikm [32]byte
	if _, err := randRead(ikm[:]); err != nil {
		return "", fmt.Errorf("reading entropy: %w", err)
	}
	sk := blst.KeyGen(ikm[:])
	if sk == nil {
		return "", fmt.Errorf("BLS key generation failed")
	}
	defer sk.Zeroize()
	return hex.EncodeToString(sk.Serialize()), nil
}

func publicKeyHex(skHex string) (string, error) {
	sk, err := deserialize(skHex)
	if err != nil {
		return "", err
	}
	defer sk.Zeroize()
	pk := new(blst.P1Affine).From(sk)
	if pk == nil {
		return "", fmt.Errorf("BLS public key derivation failed")
	}
	return hex.EncodeToString(pk.Compress()), nil
}

func sign(skHex, msgHex, dstHex string) (string, error) {
	sk, err := deserialize(skHex)
	if err != nil {
		return "", err
	}
	defer sk.Zeroize()
	msg, err := hex.DecodeString(msgHex)
	if err != nil {
		return "", fmt.Errorf("decoding message: %w", err)
	}
	dst, err := hex.DecodeString(dstHex)
	if err != nil {
		return "", fmt.Errorf("decoding DST: %w", err)
	}
	sig := new(blst.P2Affine).Sign(sk, msg, dst)
	if sig == nil {
		return "", fmt.Errorf("BLS sign failed")
	}
	return hex.EncodeToString(sig.Compress()), nil
}

func deserialize(skHex string) (*blst.SecretKey, error) {
	skBytes, err := hex.DecodeString(skHex)
	if err != nil {
		return nil, fmt.Errorf("decoding key hex: %w", err)
	}
	if len(skBytes) != 32 {
		return nil, fmt.Errorf("expected 32-byte key, got %d", len(skBytes))
	}
	sk := new(blst.SecretKey)
	if sk.Deserialize(skBytes) == nil {
		return nil, fmt.Errorf("invalid BLS scalar")
	}
	return sk, nil
}
