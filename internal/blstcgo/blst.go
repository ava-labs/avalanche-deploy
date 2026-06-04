// Copyright (C) 2024, Ava Labs, Inc. All rights reserved.
// See the file LICENSE for licensing terms.

// Package blstcgo provides a minimal CGO wrapper over the blst BLS12-381
// library.  It exposes only the three operations needed by the signer backends
// and never leaks CGO types into the Go API, which avoids the Go 1.22+
// restriction on defining methods on CGO type aliases.
package blstcgo

// #cgo CFLAGS: -I${SRCDIR} -I${SRCDIR}/src -I${SRCDIR}/build
// #cgo CFLAGS: -D__BLST_CGO__ -fno-builtin-memcpy -fno-builtin-memset
// #cgo arm64 CFLAGS: -march=armv8-a
// #cgo amd64 CFLAGS: -D__ADX__ -mno-avx
// #cgo mips64 mips64le ppc64 ppc64le riscv64 s390x CFLAGS: -D__BLST_NO_ASM__
// #include "bridge.h"
import "C"

import (
	"fmt"
	"unsafe"
)

const (
	SecretKeySize = 32
	PublicKeySize = 48
	SignatureSize = 96
)

// ValidateSecretKey returns true if skBytes is a valid 32-byte BLS12-381
// secret key scalar (non-zero and less than the curve order).
func ValidateSecretKey(skBytes []byte) bool {
	if len(skBytes) != SecretKeySize {
		return false
	}
	return C.bls_sk_valid((*C.uint8_t)(unsafe.Pointer(&skBytes[0]))) == 1
}

// PublicKey derives the 48-byte compressed G1 public key from skBytes.
func PublicKey(skBytes []byte) ([]byte, error) {
	if len(skBytes) != SecretKeySize {
		return nil, fmt.Errorf("expected %d-byte secret key, got %d", SecretKeySize, len(skBytes))
	}
	out := make([]byte, PublicKeySize)
	C.bls_public_key(
		(*C.uint8_t)(unsafe.Pointer(&out[0])),
		(*C.uint8_t)(unsafe.Pointer(&skBytes[0])),
	)
	return out, nil
}

// KeyGen derives a valid BLS12-381 secret key from input key material (IKM)
// using the standard HKDF-based derivation (draft-irtf-cfrg-bls-signature).
// ikm must be at least 32 bytes of high-entropy data.
// The returned scalar is guaranteed to be non-zero and less than the curve order.
func KeyGen(ikm []byte) ([]byte, error) {
	if len(ikm) < 32 {
		return nil, fmt.Errorf("IKM must be at least 32 bytes, got %d", len(ikm))
	}
	out := make([]byte, SecretKeySize)
	C.bls_keygen(
		(*C.uint8_t)(unsafe.Pointer(&out[0])),
		(*C.uint8_t)(unsafe.Pointer(&ikm[0])),
		C.size_t(len(ikm)),
	)
	return out, nil
}

// Sign hashes msg to G2 with the given DST and signs it with skBytes,
// returning a 96-byte compressed G2 signature.
func Sign(skBytes, msg, dst []byte) ([]byte, error) {
	if len(skBytes) != SecretKeySize {
		return nil, fmt.Errorf("expected %d-byte secret key, got %d", SecretKeySize, len(skBytes))
	}
	if len(msg) == 0 {
		return nil, fmt.Errorf("message must not be empty")
	}
	out := make([]byte, SignatureSize)
	C.bls_sign(
		(*C.uint8_t)(unsafe.Pointer(&out[0])),
		(*C.uint8_t)(unsafe.Pointer(&skBytes[0])),
		(*C.uint8_t)(unsafe.Pointer(&msg[0])), C.size_t(len(msg)),
		(*C.uint8_t)(unsafe.Pointer(&dst[0])), C.size_t(len(dst)),
	)
	return out, nil
}
