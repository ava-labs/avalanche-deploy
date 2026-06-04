// Copyright (C) 2024, Ava Labs, Inc. All rights reserved.
// See the file LICENSE for licensing terms.

package backend

import (
	"context"
	"fmt"

	"github.com/hashicorp/vault/sdk/framework"
	"github.com/hashicorp/vault/sdk/logical"
)

// storageKeyPrefix is the prefix for BLS key entries in Vault storage.
const storageKeyPrefix = "keys/"

func pathKeys(b *backend) []*framework.Path {
	return []*framework.Path{
		{
			Pattern: "keys/" + framework.GenericNameRegex("name") + "/generate",
			Fields: map[string]*framework.FieldSchema{
				"name": {
					Type:        framework.TypeString,
					Description: "Name of the BLS key to generate.",
				},
			},
			ExistenceCheck: b.keyDoesNotExist,
			Operations: map[logical.Operation]framework.OperationHandler{
				logical.CreateOperation: &framework.PathOperation{Callback: b.handleGenerate},
				logical.UpdateOperation: &framework.PathOperation{Callback: b.handleGenerate},
			},
			HelpSynopsis:    "Generate a new BLS12-381 key.",
			HelpDescription: "Generates a new BLS12-381 key using HKDF key derivation and stores it in Vault's encrypted storage. The key is never returned.",
		},
		{
			Pattern: "keys/" + framework.GenericNameRegex("name") + "/public-key",
			Fields: map[string]*framework.FieldSchema{
				"name": {
					Type:        framework.TypeString,
					Description: "Name of the BLS key.",
				},
			},
			Operations: map[logical.Operation]framework.OperationHandler{
				logical.ReadOperation: &framework.PathOperation{Callback: b.handlePublicKey},
			},
			HelpSynopsis:    "Return the compressed BLS public key.",
			HelpDescription: "Returns the 48-byte compressed G1 public key as a hex string.",
		},
	}
}

func (b *backend) handleGenerate(ctx context.Context, req *logical.Request, d *framework.FieldData) (*logical.Response, error) {
	name := d.Get("name").(string)

	// Check if key already exists.
	entry, err := req.Storage.Get(ctx, storageKeyPrefix+name)
	if err != nil {
		return nil, fmt.Errorf("storage read: %w", err)
	}
	if entry != nil {
		return logical.ErrorResponse("key %q already exists — delete it first to regenerate", name), nil
	}

	skHex, err := generateKey()
	if err != nil {
		return nil, fmt.Errorf("generating key: %w", err)
	}

	pkHex, err := publicKeyHex(skHex)
	if err != nil {
		return nil, fmt.Errorf("deriving public key: %w", err)
	}

	// Store only the hex-encoded scalar — never return it via the API.
	if err := req.Storage.Put(ctx, &logical.StorageEntry{
		Key:   storageKeyPrefix + name,
		Value: []byte(skHex),
	}); err != nil {
		return nil, fmt.Errorf("storage write: %w", err)
	}

	return &logical.Response{
		Data: map[string]interface{}{
			"name":       name,
			"public_key": pkHex,
		},
	}, nil
}

func (b *backend) handlePublicKey(ctx context.Context, req *logical.Request, d *framework.FieldData) (*logical.Response, error) {
	name := d.Get("name").(string)

	skHex, err := loadKey(ctx, req.Storage, name)
	if err != nil {
		return nil, err
	}
	if skHex == "" {
		return logical.ErrorResponse("key %q not found", name), nil
	}

	pkHex, err := publicKeyHex(skHex)
	if err != nil {
		return nil, fmt.Errorf("deriving public key: %w", err)
	}

	return &logical.Response{
		Data: map[string]interface{}{
			"public_key": pkHex,
		},
	}, nil
}

// keyExists is the ExistenceCheck for sign paths — returns true if the key exists.
func (b *backend) keyExists(ctx context.Context, req *logical.Request, d *framework.FieldData) (bool, error) {
	name := d.Get("name").(string)
	entry, err := req.Storage.Get(ctx, storageKeyPrefix+name)
	if err != nil {
		return false, err
	}
	return entry != nil, nil
}

// keyDoesNotExist is the ExistenceCheck for the generate path.
// Returns false (does not exist) always so CreateOperation always fires.
func (b *backend) keyDoesNotExist(ctx context.Context, req *logical.Request, d *framework.FieldData) (bool, error) {
	name := d.Get("name").(string)
	entry, err := req.Storage.Get(ctx, storageKeyPrefix+name)
	if err != nil {
		return false, err
	}
	return entry != nil, nil
}

// loadKey reads and returns the hex-encoded BLS scalar from Vault storage.
func loadKey(ctx context.Context, s logical.Storage, name string) (string, error) {
	entry, err := s.Get(ctx, storageKeyPrefix+name)
	if err != nil {
		return "", fmt.Errorf("storage read: %w", err)
	}
	if entry == nil {
		return "", nil
	}
	return string(entry.Value), nil
}
