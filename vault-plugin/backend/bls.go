// Copyright (C) 2024, Ava Labs, Inc. All rights reserved.
// See the file LICENSE for licensing terms.

// Package backend — BLS12-381 cryptographic primitives used by the plugin.
// This file is a thin CGO wrapper over blst so the plugin binary has its own
// copy of the BLS operations independent of the main signer binary.

package backend

// #cgo CFLAGS: -I${SRCDIR}/blst_src -I${SRCDIR}/blst_src/src -I${SRCDIR}/blst_src/build
// #cgo CFLAGS: -D__BLST_CGO__ -fno-builtin-memcpy -fno-builtin-memset
// #cgo arm64 CFLAGS: -march=armv8-a
// #cgo amd64 CFLAGS: -D__ADX__ -mno-avx
// #cgo mips64 mips64le ppc64 ppc64le riscv64 s390x CFLAGS: -D__BLST_NO_ASM__
// #include "bridge.h"
import "C"

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"unsafe"
)

const (
	secretKeySize = 32
	publicKeySize = 48
	signatureSize = 96
)

// generateKey produces a new BLS12-381 secret key using HKDF key derivation
// and returns the 32-byte scalar as a hex string for storage in Vault.
func generateKey() (string, error) {
	var ikm [32]byte
	if _, err := rand.Read(ikm[:]); err != nil {
		return "", fmt.Errorf("reading entropy: %w", err)
	}
	out := make([]byte, secretKeySize)
	C.bls_keygen(
		(*C.uint8_t)(unsafe.Pointer(&out[0])),
		(*C.uint8_t)(unsafe.Pointer(&ikm[0])),
		C.size_t(len(ikm)),
	)
	return hex.EncodeToString(out), nil
}

// publicKeyHex derives the compressed G1 public key from a hex-encoded scalar.
func publicKeyHex(skHex string) (string, error) {
	skBytes, err := hex.DecodeString(skHex)
	if err != nil {
		return "", fmt.Errorf("decoding key: %w", err)
	}
	if len(skBytes) != secretKeySize {
		return "", fmt.Errorf("expected 32-byte key, got %d", len(skBytes))
	}
	out := make([]byte, publicKeySize)
	C.bls_public_key(
		(*C.uint8_t)(unsafe.Pointer(&out[0])),
		(*C.uint8_t)(unsafe.Pointer(&skBytes[0])),
	)
	return hex.EncodeToString(out), nil
}

// sign hashes msg to G2 with dst and signs it with the key stored as skHex.
// Returns the compressed 96-byte G2 signature as hex.
func sign(skHex string, msgHex string, dstHex string) (string, error) {
	skBytes, err := hex.DecodeString(skHex)
	if err != nil {
		return "", fmt.Errorf("decoding key: %w", err)
	}
	msg, err := hex.DecodeString(msgHex)
	if err != nil {
		return "", fmt.Errorf("decoding message: %w", err)
	}
	dst, err := hex.DecodeString(dstHex)
	if err != nil {
		return "", fmt.Errorf("decoding DST: %w", err)
	}
	if len(skBytes) != secretKeySize {
		return "", fmt.Errorf("expected 32-byte key, got %d", len(skBytes))
	}
	if len(msg) == 0 {
		return "", fmt.Errorf("message must not be empty")
	}
	if len(dst) == 0 {
		return "", fmt.Errorf("DST must not be empty")
	}
	out := make([]byte, signatureSize)
	C.bls_sign(
		(*C.uint8_t)(unsafe.Pointer(&out[0])),
		(*C.uint8_t)(unsafe.Pointer(&skBytes[0])),
		(*C.uint8_t)(unsafe.Pointer(&msg[0])), C.size_t(len(msg)),
		(*C.uint8_t)(unsafe.Pointer(&dst[0])), C.size_t(len(dst)),
	)
	return hex.EncodeToString(out), nil
}
