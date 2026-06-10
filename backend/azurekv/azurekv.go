// Copyright (C) 2024, Ava Labs, Inc. All rights reserved.
// See the file LICENSE for licensing terms.

// Package azurekv implements the Backend interface using Azure Key Vault.
package azurekv

import (
	"context"
	"fmt"
	"log/slog"
	"os"

	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
	"github.com/Azure/azure-sdk-for-go/sdk/security/keyvault/azkeys"

	signerconfig "github.com/ava-labs/avalanche-remote-signer/config"
	"github.com/ava-labs/avalanche-remote-signer/internal/blstutil"
)

// Domain separation tags — single source of truth in blstutil,
// cross-checked against AvalancheGo by the tests in compat/.
var (
	dstSign     = blstutil.DSTSign
	dstPopProve = blstutil.DSTPoP
)

type kvClient interface {
	Decrypt(ctx context.Context, keyName, keyVersion string, params azkeys.KeyOperationParameters, opts *azkeys.DecryptOptions) (azkeys.DecryptResponse, error)
	Encrypt(ctx context.Context, keyName, keyVersion string, params azkeys.KeyOperationParameters, opts *azkeys.EncryptOptions) (azkeys.EncryptResponse, error)
}

// Backend holds a BLS secret key decrypted from an Azure Key Vault-wrapped blob.
type Backend struct {
	skBytes []byte
	pkBytes []byte
	log     *slog.Logger
}

// New loads and decrypts the BLS key from disk using an Azure Key Vault RSA key.
func New(cfg signerconfig.AzureConfig, log *slog.Logger) (*Backend, error) {
	cred, err := azidentity.NewDefaultAzureCredential(nil)
	if err != nil {
		return nil, fmt.Errorf("creating Azure credential: %w", err)
	}
	client, err := azkeys.NewClient(cfg.VaultURL, cred, nil)
	if err != nil {
		return nil, fmt.Errorf("creating Azure Key Vault client: %w", err)
	}
	return newWithClient(cfg, log, client)
}

func newWithClient(cfg signerconfig.AzureConfig, log *slog.Logger, client kvClient) (*Backend, error) {
	ciphertext, err := os.ReadFile(cfg.EncryptedBLSKeyPath)
	if err != nil {
		return nil, fmt.Errorf("reading encrypted key %q: %w", cfg.EncryptedBLSKeyPath, err)
	}

	algo := azkeys.EncryptionAlgorithmRSAOAEP256
	resp, err := client.Decrypt(context.Background(), cfg.KeyName, "", azkeys.KeyOperationParameters{
		Algorithm: &algo,
		Value:     ciphertext,
	}, nil)
	if err != nil {
		return nil, fmt.Errorf("Azure KV decrypt: %w", err)
	}

	return backendFromBytes(resp.Result, log)
}

func backendFromBytes(skBytes []byte, log *slog.Logger) (*Backend, error) {
	if len(skBytes) != blstutil.SecretKeySize {
		return nil, fmt.Errorf("expected %d-byte BLS scalar, got %d bytes", blstutil.SecretKeySize, len(skBytes))
	}
	if !blstutil.ValidateSecretKey(skBytes) {
		return nil, fmt.Errorf("invalid BLS key material")
	}
	pkBytes, err := blstutil.PublicKey(skBytes)
	if err != nil {
		return nil, fmt.Errorf("BLS public key derivation: %w", err)
	}
	return &Backend{skBytes: skBytes, pkBytes: pkBytes, log: log}, nil
}

func (b *Backend) PublicKey(_ context.Context) ([]byte, error) { return b.pkBytes, nil }

func (b *Backend) Sign(_ context.Context, msg []byte) ([]byte, error) {
	return blstutil.Sign(b.skBytes, msg, dstSign)
}

func (b *Backend) SignProofOfPossession(_ context.Context, msg []byte) ([]byte, error) {
	return blstutil.Sign(b.skBytes, msg, dstPopProve)
}

func (b *Backend) Close() error {
	for i := range b.skBytes {
		b.skBytes[i] = 0
	}
	return nil
}

// Encrypt encrypts plaintext using Azure Key Vault. Used by keytool.
func Encrypt(ctx context.Context, client kvClient, keyName string, plaintext []byte) ([]byte, error) {
	algo := azkeys.EncryptionAlgorithmRSAOAEP256
	resp, err := client.Encrypt(ctx, keyName, "", azkeys.KeyOperationParameters{
		Algorithm: &algo,
		Value:     plaintext,
	}, nil)
	if err != nil {
		return nil, fmt.Errorf("Azure KV encrypt: %w", err)
	}
	return resp.Result, nil
}

// NewKVClient builds a production Azure Key Vault client. Exported for keytool.
func NewKVClient(vaultURL string) (*azkeys.Client, error) {
	cred, err := azidentity.NewDefaultAzureCredential(nil)
	if err != nil {
		return nil, fmt.Errorf("creating Azure credential: %w", err)
	}
	client, err := azkeys.NewClient(vaultURL, cred, nil)
	if err != nil {
		return nil, fmt.Errorf("creating Azure Key Vault client: %w", err)
	}
	return client, nil
}
