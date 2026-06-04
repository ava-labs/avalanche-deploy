// Copyright (C) 2024, Ava Labs, Inc. All rights reserved.
// See the file LICENSE for licensing terms.

// Package backend defines the Backend interface that every signing backend
// must implement.  The signerserver delegates all cryptographic operations
// here, so adding a new KMS provider means implementing this interface and
// registering it in main — no other code changes required.
package backend

import "context"

// Backend is the signing abstraction.  Implementations must be safe for
// concurrent use; AvalancheGo may call Sign and SignProofOfPossession from
// multiple goroutines.
type Backend interface {
	// PublicKey returns the 48-byte compressed BLS public key that
	// corresponds to the private key held by this backend.
	PublicKey(ctx context.Context) ([]byte, error)

	// Sign returns a BLS signature over msg using the Warp message signing
	// domain separation tag used by AvalancheGo for ICM messages.
	Sign(ctx context.Context, msg []byte) ([]byte, error)

	// SignProofOfPossession returns a BLS signature over msg using the
	// proof-of-possession domain separation tag used by AvalancheGo during
	// peer handshakes.
	SignProofOfPossession(ctx context.Context, msg []byte) ([]byte, error)

	// Close releases any resources held by the backend (connections,
	// decrypted key material, etc.).  It is called once on shutdown.
	Close() error
}
