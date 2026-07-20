// Copyright (C) 2024, Ava Labs, Inc. All rights reserved.
// See the file LICENSE for licensing terms.

package backend

import (
	"context"
	"fmt"

	"github.com/hashicorp/vault/sdk/framework"
	"github.com/hashicorp/vault/sdk/helper/locksutil"
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
			ExistenceCheck: b.keyExists,
			Operations: map[logical.Operation]framework.OperationHandler{
				logical.CreateOperation: &framework.PathOperation{Callback: b.handleGenerate},
				logical.UpdateOperation: &framework.PathOperation{Callback: b.handleGenerate},
			},
			HelpSynopsis:    "Generate a new BLS12-381 key.",
			HelpDescription: "Generates a new BLS12-381 key using HKDF key derivation and stores it in Vault's encrypted storage. The key is never returned.",
		},
		{
			// import accepts a hex-encoded BLS scalar from an existing plaintext
			// signer.key and stores it in Vault's encrypted storage.
			// This is used by `keytool migrate --backend vault`.
			Pattern: "keys/" + framework.GenericNameRegex("name") + "/import",
			Fields: map[string]*framework.FieldSchema{
				"name": {
					Type:        framework.TypeString,
					Description: "Name to store the imported BLS key under.",
				},
				"key": {
					Type:        framework.TypeString,
					Description: "Hex-encoded 32-byte BLS scalar to import.",
				},
			},
			ExistenceCheck: b.keyExists,
			Operations: map[logical.Operation]framework.OperationHandler{
				logical.CreateOperation: &framework.PathOperation{Callback: b.handleImport},
				logical.UpdateOperation: &framework.PathOperation{Callback: b.handleImport},
			},
			HelpSynopsis:    "Import an existing BLS key into Vault.",
			HelpDescription: "Accepts a hex-encoded 32-byte BLS scalar and stores it in Vault's encrypted storage. The key is validated before storage. Used by keytool migrate.",
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
		{
			// Bare keys/<name> — delete a stored key. Enables rotation (generate
			// and import refuse to overwrite an existing key, and tell the caller
			// to delete first). GenericNameRegex has no "/…" suffix, so this only
			// matches keys/<name>, never the operation sub-paths.
			Pattern: "keys/" + framework.GenericNameRegex("name"),
			Fields: map[string]*framework.FieldSchema{
				"name": {
					Type:        framework.TypeString,
					Description: "Name of the BLS key to delete.",
				},
			},
			Operations: map[logical.Operation]framework.OperationHandler{
				logical.DeleteOperation: &framework.PathOperation{Callback: b.handleDelete},
			},
			HelpSynopsis: "Delete a stored BLS key.",
			HelpDescription: "Permanently deletes the stored BLS key. This destroys the " +
				"validator's signing identity — it cannot be recovered unless the scalar " +
				"was separately backed up. Intended for key rotation/decommissioning.",
		},
	}
}

func (b *backend) handleDelete(ctx context.Context, req *logical.Request, d *framework.FieldData) (*logical.Response, error) {
	name := d.Get("name").(string)

	// Same per-key lock the writers hold, so a delete can't race a
	// concurrent generate/import for the same name.
	lock := locksutil.LockForKey(b.locks, name)
	lock.Lock()
	defer lock.Unlock()

	if err := req.Storage.Delete(ctx, storageKeyPrefix+name); err != nil {
		return nil, fmt.Errorf("storage delete: %w", err)
	}
	return nil, nil
}

func (b *backend) handleGenerate(ctx context.Context, req *logical.Request, d *framework.FieldData) (*logical.Response, error) {
	name := d.Get("name").(string)

	// Hold the per-key write lock across the exists-check + write so a
	// concurrent generate/import for the same name can't clobber this key.
	lock := locksutil.LockForKey(b.locks, name)
	lock.Lock()
	defer lock.Unlock()

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

func (b *backend) handleImport(ctx context.Context, req *logical.Request, d *framework.FieldData) (*logical.Response, error) {
	name := d.Get("name").(string)
	keyHex, ok := d.GetOk("key")
	if !ok {
		return logical.ErrorResponse("key is required"), nil
	}

	skHex := keyHex.(string)
	if len(skHex) != 64 {
		return logical.ErrorResponse("key must be a 64-character hex string (32 bytes)"), nil
	}

	// Validate the key by deriving the public key — this confirms it's a valid scalar.
	// User-input failure → 400 ErrorResponse, and don't echo the (invalid) key
	// bytes that a wrapped hex/scalar error would carry.
	pkHex, err := publicKeyHex(skHex)
	if err != nil {
		return logical.ErrorResponse("invalid BLS key: not a valid 32-byte scalar"), nil
	}

	// Hold the per-key write lock across the exists-check + write so a
	// concurrent generate/import for the same name can't clobber this key.
	lock := locksutil.LockForKey(b.locks, name)
	lock.Lock()
	defer lock.Unlock()

	// Check if key already exists.
	entry, err := req.Storage.Get(ctx, storageKeyPrefix+name)
	if err != nil {
		return nil, fmt.Errorf("storage read: %w", err)
	}
	if entry != nil {
		return logical.ErrorResponse("key %q already exists — delete it first to overwrite", name), nil
	}

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

// keyExists is the ExistenceCheck for the generate/import/sign paths — it
// reports whether the named key already exists so the framework routes to
// Create vs Update. Both map to the same handler, and the handlers re-check
// under the per-key lock, so this only affects which operation label fires.
func (b *backend) keyExists(ctx context.Context, req *logical.Request, d *framework.FieldData) (bool, error) {
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
