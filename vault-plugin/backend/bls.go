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

func generateKey() (string, error) {
	var ikm [32]byte
	if _, err := randRead(ikm[:]); err != nil {
		return "", fmt.Errorf("reading entropy: %w", err)
	}
	sk := blst.KeyGen(ikm[:])
	if sk == nil {
		return "", fmt.Errorf("BLS key generation failed")
	}
	return hex.EncodeToString(sk.Serialize()), nil
}

func publicKeyHex(skHex string) (string, error) {
	sk, err := deserialize(skHex)
	if err != nil {
		return "", err
	}
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
