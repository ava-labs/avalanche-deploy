// Copyright (C) 2024, Ava Labs, Inc. All rights reserved.
// See the file LICENSE for licensing terms.

// Package backend implements the Vault secrets plugin backend for BLS12-381
// signing.  Keys are stored in Vault's encrypted storage; signing happens
// inside this process — plaintext key material never crosses an API boundary.
package backend

import (
	"context"
	"fmt"

	"github.com/hashicorp/vault/sdk/framework"
	"github.com/hashicorp/vault/sdk/logical"
)

// backend is the Vault plugin backend.
type backend struct {
	*framework.Backend
}

// Factory is the Vault plugin factory function registered in main.go.
func Factory(ctx context.Context, conf *logical.BackendConfig) (logical.Backend, error) {
	b := &backend{}
	b.Backend = &framework.Backend{
		Help:        backendHelp,
		BackendType: logical.TypeLogical,
		Paths: framework.PathAppend(
			pathKeys(b),
			pathSign(b),
		),
		Secrets: []*framework.Secret{},
	}
	if err := b.Setup(ctx, conf); err != nil {
		return nil, fmt.Errorf("setup: %w", err)
	}
	return b, nil
}

const backendHelp = `
The BLS signer backend stores BLS12-381 keys in Vault's encrypted storage
and performs signing operations internally.

Keys are never returned via the API — only the compressed public key is
readable.  Signing requests provide the message and DST; the backend
returns the compressed G2 signature.
`
