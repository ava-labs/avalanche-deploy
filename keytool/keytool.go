// Copyright (C) 2024, Ava Labs, Inc. All rights reserved.
// See the file LICENSE for licensing terms.

// Package keytool implements the key management CLI subcommands:
//
//   - generate: create a new BLS key and encrypt it with the chosen backend.
//   - migrate:  read an existing signer.key, encrypt it with the chosen
//     backend, and optionally securely delete the plaintext.
//
// Usage:
//
//	avalanche-kms-signer keytool generate --backend aws-kms [flags]
//	avalanche-kms-signer keytool migrate  --backend aws-kms --input ~/.avalanchego/staking/signer.key
package keytool

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"

	vault "github.com/hashicorp/vault/api"

	"github.com/ava-labs/avalanche-remote-signer/backend/awskms"
	"github.com/ava-labs/avalanche-remote-signer/backend/azurekv"
	"github.com/ava-labs/avalanche-remote-signer/backend/gcpkms"
	"github.com/ava-labs/avalanche-remote-signer/config"
	"github.com/ava-labs/avalanche-remote-signer/internal/blstutil"
)

// GenerateOpts holds parameters for the generate subcommand.
type GenerateOpts struct {
	// Backend selects the KMS provider (aws-kms, gcp-kms, azure-kv).
	Backend string

	// OutputPath is where the encrypted key blob will be written.
	OutputPath string

	// AWS holds AWS-specific settings (used when Backend == "aws-kms").
	AWS config.AWSConfig

	// GCP holds GCP-specific settings (used when Backend == "gcp-kms").
	GCP config.GCPConfig

	// Azure holds Azure-specific settings (used when Backend == "azure-kv").
	Azure config.AzureConfig

	// Vault holds Vault-specific settings (used when Backend == "vault").
	// For Vault, no output file is written — the key is stored inside Vault.
	Vault config.VaultConfig
}

// Generate creates a new BLS12-381 key, encrypts it with the specified KMS
// backend, and writes the encrypted blob to opts.OutputPath.
// It returns the hex-encoded compressed public key so the caller can display
// it for on-chain verification.
func Generate(opts GenerateOpts) (publicKeyHex string, err error) {
	// Vault generates the key internally — no local key material needed.
	if config.BackendType(opts.Backend) == config.BackendVault {
		return vaultGenerate(opts.Vault)
	}

	skBytes, err := generateBLSKey()
	if err != nil {
		return "", err
	}
	pkBytes, err := blstutil.PublicKey(skBytes)
	if err != nil {
		return "", fmt.Errorf("deriving public key: %w", err)
	}
	ciphertext, err := encryptForBackend(opts.Backend, opts.AWS, opts.GCP, opts.Azure, skBytes)
	if err != nil {
		return "", err
	}
	if err := writeFile(opts.OutputPath, ciphertext); err != nil {
		return "", err
	}
	return hex.EncodeToString(pkBytes), nil
}

// MigrateOpts holds parameters for the migrate subcommand.
type MigrateOpts struct {
	// Backend selects the KMS provider.
	Backend string

	// InputPath is the path to the existing plaintext signer.key file
	// (32-byte raw BLS scalar, as written by AvalancheGo).
	InputPath string

	// OutputPath is where the encrypted blob will be written.
	OutputPath string

	// DeleteInput, if true, securely overwrites and then removes the
	// plaintext key file after a successful migration.
	DeleteInput bool

	// AWS, GCP, Azure, Vault hold provider-specific settings.
	AWS   config.AWSConfig
	GCP   config.GCPConfig
	Azure config.AzureConfig
	Vault config.VaultConfig
}

// Migrate reads a plaintext signer.key, encrypts it with the specified KMS
// backend, writes the encrypted blob to opts.OutputPath, and optionally
// securely deletes the plaintext file.
// It returns the hex-encoded compressed public key so the caller can verify it
// matches the BLS key registered on-chain for this validator.
//
// IMPORTANT: confirm the printed public key matches what avalanche-cli node list
// shows before deleting the plaintext key.
func Migrate(opts MigrateOpts) (publicKeyHex string, err error) {
	skBytes, err := os.ReadFile(opts.InputPath)
	if err != nil {
		return "", fmt.Errorf("reading plaintext key %q: %w", opts.InputPath, err)
	}
	if len(skBytes) != 32 {
		return "", fmt.Errorf("expected 32-byte BLS scalar in %q, got %d bytes", opts.InputPath, len(skBytes))
	}
	if !blstutil.ValidateSecretKey(skBytes) {
		return "", fmt.Errorf("%q does not contain a valid BLS scalar", opts.InputPath)
	}

	// Vault import: send the key to Vault's encrypted storage directly.
	if config.BackendType(opts.Backend) == config.BackendVault {
		pkHex, err := vaultImport(opts.Vault, skBytes)
		if err != nil {
			return "", err
		}
		if opts.DeleteInput {
			if err := secureDelete(opts.InputPath); err != nil {
				return "", fmt.Errorf("secure delete of %q failed: %w — MANUAL DELETION REQUIRED", opts.InputPath, err)
			}
		}
		return pkHex, nil
	}

	pkBytes, err := blstutil.PublicKey(skBytes)
	if err != nil {
		return "", fmt.Errorf("deriving public key: %w", err)
	}

	ciphertext, err := encryptForBackend(opts.Backend, opts.AWS, opts.GCP, opts.Azure, skBytes)
	if err != nil {
		return "", err
	}

	if err := writeFile(opts.OutputPath, ciphertext); err != nil {
		return "", err
	}

	if opts.DeleteInput {
		if err := secureDelete(opts.InputPath); err != nil {
			return "", fmt.Errorf("secure delete of %q failed: %w — MANUAL DELETION REQUIRED", opts.InputPath, err)
		}
	}
	return hex.EncodeToString(pkBytes), nil
}

// vaultGenerate calls the Vault plugin's generate endpoint to create a new
// BLS key inside Vault. The key never leaves Vault's process.
func vaultGenerate(cfg config.VaultConfig) (string, error) {
	client, err := vaultClient(cfg)
	if err != nil {
		return "", err
	}
	mountPath := cfg.MountPath
	if mountPath == "" {
		mountPath = "bls"
	}
	path := fmt.Sprintf("%s/keys/%s/generate", mountPath, cfg.KeyName)
	secret, err := client.Logical().Write(path, nil)
	if err != nil {
		return "", fmt.Errorf("Vault generate: %w", err)
	}
	if secret == nil || secret.Data == nil {
		return "", fmt.Errorf("Vault returned empty response")
	}
	pkHex, ok := secret.Data["public_key"].(string)
	if !ok {
		return "", fmt.Errorf("unexpected public_key type in Vault response")
	}
	return pkHex, nil
}

// vaultImport sends a plaintext BLS scalar to the Vault plugin's import
// endpoint, which validates and stores it in Vault's encrypted storage.
func vaultImport(cfg config.VaultConfig, skBytes []byte) (string, error) {
	client, err := vaultClient(cfg)
	if err != nil {
		return "", err
	}
	mountPath := cfg.MountPath
	if mountPath == "" {
		mountPath = "bls"
	}
	path := fmt.Sprintf("%s/keys/%s/import", mountPath, cfg.KeyName)
	secret, err := client.Logical().Write(path, map[string]interface{}{
		"key": hex.EncodeToString(skBytes),
	})
	if err != nil {
		return "", fmt.Errorf("Vault import: %w", err)
	}
	if secret == nil || secret.Data == nil {
		return "", fmt.Errorf("Vault returned empty response")
	}
	pkHex, ok := secret.Data["public_key"].(string)
	if !ok {
		return "", fmt.Errorf("unexpected public_key type in Vault response")
	}
	return pkHex, nil
}

// vaultClient builds an authenticated Vault API client.
func vaultClient(cfg config.VaultConfig) (*vault.Client, error) {
	vaultCfg := vault.DefaultConfig()
	vaultCfg.Address = cfg.Address
	client, err := vault.NewClient(vaultCfg)
	if err != nil {
		return nil, fmt.Errorf("creating Vault client: %w", err)
	}
	if cfg.Token == "" {
		return nil, fmt.Errorf("vault.token must be set for keytool (auth_method=token)")
	}
	client.SetToken(cfg.Token)
	return client, nil
}

// generateBLSKey generates a fresh BLS12-381 secret key and returns its
// 32-byte serialised scalar.
func generateBLSKey() ([]byte, error) {
	var ikm [32]byte
	if _, err := rand.Read(ikm[:]); err != nil {
		return nil, fmt.Errorf("reading random bytes: %w", err)
	}
	return blstutil.KeyGen(ikm[:])
}

// encryptForBackend dispatches to the appropriate KMS encrypt helper.
func encryptForBackend(
	backend string,
	awsCfg config.AWSConfig,
	gcpCfg config.GCPConfig,
	azureCfg config.AzureConfig,
	plaintext []byte,
) ([]byte, error) {
	ctx := context.Background()
	switch config.BackendType(backend) {
	case config.BackendAWSKMS:
		client, err := awskms.NewKMSClient(awsCfg)
		if err != nil {
			return nil, err
		}
		return awskms.Encrypt(ctx, client, awsCfg.KMSKeyID, plaintext)

	case config.BackendGCPKMS:
		client, err := gcpkms.NewKMSClient(ctx)
		if err != nil {
			return nil, err
		}
		defer client.Close()
		keyName := fmt.Sprintf("projects/%s/locations/%s/keyRings/%s/cryptoKeys/%s",
			gcpCfg.Project, gcpCfg.Location, gcpCfg.KeyRing, gcpCfg.KeyName)
		return gcpkms.Encrypt(ctx, client, keyName, plaintext)

	case config.BackendAzureKV:
		client, err := azurekv.NewKVClient(azureCfg.VaultURL)
		if err != nil {
			return nil, err
		}
		return azurekv.Encrypt(ctx, client, azureCfg.KeyName, plaintext)

	default:
		return nil, fmt.Errorf("unsupported backend %q — valid options: aws-kms, gcp-kms, azure-kv", backend)
	}
}

// writeFile writes data to path with restrictive permissions (0600).
func writeFile(path string, data []byte) error {
	if err := os.WriteFile(path, data, 0600); err != nil {
		return fmt.Errorf("writing encrypted key to %q: %w", path, err)
	}
	return nil
}

// secureDelete overwrites the file with zeros before removing it.
// This is a best-effort defence against simple file recovery; it does not
// account for SSDs with wear-levelling or filesystem snapshots.
func secureDelete(path string) error {
	f, err := os.OpenFile(path, os.O_WRONLY, 0)
	if err != nil {
		return err
	}
	info, err := f.Stat()
	if err != nil {
		f.Close()
		return err
	}
	zeros := make([]byte, info.Size())
	if _, err := f.Write(zeros); err != nil {
		f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	f.Close()
	return os.Remove(path)
}
