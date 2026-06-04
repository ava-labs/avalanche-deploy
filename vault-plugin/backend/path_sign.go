// Copyright (C) 2024, Ava Labs, Inc. All rights reserved.
// See the file LICENSE for licensing terms.

package backend

import (
	"context"
	"encoding/hex"
	"fmt"

	"github.com/hashicorp/vault/sdk/framework"
	"github.com/hashicorp/vault/sdk/logical"
)

// AvalancheGo domain separation tags — hardcoded so callers don't need to
// supply them.  The generic sign endpoint accepts an arbitrary DST for
// flexibility; sign-pop uses the PoP DST unconditionally.
var (
	dstSign     = hex.EncodeToString([]byte("BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_NUL_"))
	dstPopProve = hex.EncodeToString([]byte("BLS_POP_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_"))
)

func pathSign(b *backend) []*framework.Path {
	return []*framework.Path{
		{
			Pattern: "keys/" + framework.GenericNameRegex("name") + "/sign",
			Fields: map[string]*framework.FieldSchema{
				"name": {
					Type:        framework.TypeString,
					Description: "Name of the BLS key.",
				},
				"message": {
					Type:        framework.TypeString,
					Description: "Message to sign, hex-encoded.",
				},
				"dst": {
					Type:        framework.TypeString,
					Description: "Domain separation tag, hex-encoded. Defaults to the AvalancheGo Warp DST.",
				},
			},
			ExistenceCheck: b.keyExists,
			Operations: map[logical.Operation]framework.OperationHandler{
				logical.CreateOperation: &framework.PathOperation{Callback: b.handleSign},
				logical.UpdateOperation: &framework.PathOperation{Callback: b.handleSign},
			},
			HelpSynopsis:    "Sign a message with the BLS key.",
			HelpDescription: "Hashes the message to G2 using the provided DST and returns the compressed signature.",
		},
		{
			Pattern: "keys/" + framework.GenericNameRegex("name") + "/sign-pop",
			Fields: map[string]*framework.FieldSchema{
				"name": {
					Type:        framework.TypeString,
					Description: "Name of the BLS key.",
				},
				"message": {
					Type:        framework.TypeString,
					Description: "Message to sign, hex-encoded.",
				},
			},
			ExistenceCheck: b.keyExists,
			Operations: map[logical.Operation]framework.OperationHandler{
				logical.CreateOperation: &framework.PathOperation{Callback: b.handleSignPoP},
				logical.UpdateOperation: &framework.PathOperation{Callback: b.handleSignPoP},
			},
			HelpSynopsis:    "Sign a proof-of-possession message.",
			HelpDescription: "Signs using the AvalancheGo proof-of-possession DST.",
		},
	}
}

func (b *backend) handleSign(ctx context.Context, req *logical.Request, d *framework.FieldData) (*logical.Response, error) {
	name := d.Get("name").(string)
	msgHex, ok := d.GetOk("message")
	if !ok {
		return logical.ErrorResponse("message is required"), nil
	}

	dst := dstSign
	if v, ok := d.GetOk("dst"); ok {
		dst = v.(string)
	}

	return b.doSign(ctx, req, name, msgHex.(string), dst)
}

func (b *backend) handleSignPoP(ctx context.Context, req *logical.Request, d *framework.FieldData) (*logical.Response, error) {
	name := d.Get("name").(string)
	msgHex, ok := d.GetOk("message")
	if !ok {
		return logical.ErrorResponse("message is required"), nil
	}
	return b.doSign(ctx, req, name, msgHex.(string), dstPopProve)
}

func (b *backend) doSign(ctx context.Context, req *logical.Request, name, msgHex, dstHex string) (*logical.Response, error) {
	skHex, err := loadKey(ctx, req.Storage, name)
	if err != nil {
		return nil, err
	}
	if skHex == "" {
		return logical.ErrorResponse("key %q not found", name), nil
	}

	sigHex, err := sign(skHex, msgHex, dstHex)
	if err != nil {
		return nil, fmt.Errorf("signing: %w", err)
	}

	return &logical.Response{
		Data: map[string]interface{}{
			"signature": sigHex,
		},
	}, nil
}
