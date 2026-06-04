// Copyright (C) 2024, Ava Labs, Inc. All rights reserved.
// See the file LICENSE for licensing terms.

// Package memory provides an in-memory BLS signing backend intended for
// development and integration testing only.  It generates a fresh keypair on
// every startup and never persists anything to disk.
//
// DO NOT use this backend in production.
package memory

import (
	"context"
	"crypto/rand"
	"fmt"

	"github.com/ava-labs/avalanche-kms-signer/internal/blstcgo"
)

// Domain separation tags used by AvalancheGo.
var (
	dstSign     = []byte("BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_NUL_")
	dstPopProve = []byte("BLS_POP_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_")
)

// Backend holds a BLS secret key in memory.
type Backend struct {
	skBytes []byte // 32-byte serialised scalar
	pkBytes []byte // 48-byte compressed G1 public key (cached)
}

// New generates a fresh BLS12-381 keypair from a cryptographically random seed.
func New() (*Backend, error) {
	var ikm [32]byte
	if _, err := rand.Read(ikm[:]); err != nil {
		return nil, fmt.Errorf("reading random bytes: %w", err)
	}

	skBytes, err := blstcgo.KeyGen(ikm[:])
	if err != nil {
		return nil, fmt.Errorf("BLS key generation failed: %w", err)
	}

	pkBytes, err := blstcgo.PublicKey(skBytes)
	if err != nil {
		return nil, fmt.Errorf("BLS public key derivation failed: %w", err)
	}

	return &Backend{skBytes: skBytes, pkBytes: pkBytes}, nil
}

// PublicKey returns the 48-byte compressed BLS public key.
func (b *Backend) PublicKey(_ context.Context) ([]byte, error) {
	return b.pkBytes, nil
}

// Sign produces a BLS signature over msg using the Warp message DST.
func (b *Backend) Sign(_ context.Context, msg []byte) ([]byte, error) {
	return blstcgo.Sign(b.skBytes, msg, dstSign)
}

// SignProofOfPossession produces a BLS signature over msg using the PoP DST.
func (b *Backend) SignProofOfPossession(_ context.Context, msg []byte) ([]byte, error) {
	return blstcgo.Sign(b.skBytes, msg, dstPopProve)
}

// Close zeroes the in-memory key material.
func (b *Backend) Close() error {
	for i := range b.skBytes {
		b.skBytes[i] = 0
	}
	return nil
}
