// Copyright (C) 2024, Ava Labs, Inc. All rights reserved.
// See the file LICENSE for licensing terms.

// Package vault implements the Backend interface using a HashiCorp Vault
// secrets plugin for BLS12-381 signing.
//
// Unlike the cloud KMS backends, the BLS private key never leaves Vault's
// process boundary — signing happens inside the plugin.  This signer backend
// makes HTTP calls to the Vault API to request signatures; it never holds
// key material.
//
// Supported auth methods: token | kubernetes | aws-iam
package vault

import (
	"context"
	"encoding/hex"
	"fmt"
	"log/slog"
	"os"

	vault "github.com/hashicorp/vault/api"
	auth "github.com/hashicorp/vault/api/auth/kubernetes"

	signerconfig "github.com/ava-labs/avalanche-kms-signer/config"
)

// Domain separation tags — must match AvalancheGo exactly.
var (
	dstSign     = hex.EncodeToString([]byte("BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_NUL_"))
	dstPopProve = hex.EncodeToString([]byte("BLS_POP_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_"))
)

const defaultMountPath = "bls"
const defaultKubernetesJWTPath = "/var/run/secrets/kubernetes.io/serviceaccount/token"

// Backend holds a Vault client and the key path; no key material is stored here.
type Backend struct {
	client    *vault.Client
	mountPath string
	keyName   string
	pkBytes   []byte // cached compressed public key
	log       *slog.Logger
}

// New creates a Vault backend, authenticates, and caches the public key.
func New(cfg signerconfig.VaultConfig, log *slog.Logger) (*Backend, error) {
	vaultCfg := vault.DefaultConfig()
	vaultCfg.Address = cfg.Address

	client, err := vault.NewClient(vaultCfg)
	if err != nil {
		return nil, fmt.Errorf("creating Vault client: %w", err)
	}

	if err := authenticate(client, cfg); err != nil {
		return nil, fmt.Errorf("authenticating to Vault: %w", err)
	}

	mountPath := cfg.MountPath
	if mountPath == "" {
		mountPath = defaultMountPath
	}

	b := &Backend{
		client:    client,
		mountPath: mountPath,
		keyName:   cfg.KeyName,
		log:       log,
	}

	// Cache the public key at boot.
	pkHex, err := b.fetchPublicKey(context.Background())
	if err != nil {
		return nil, fmt.Errorf("fetching public key from Vault: %w", err)
	}
	pkBytes, err := hex.DecodeString(pkHex)
	if err != nil {
		return nil, fmt.Errorf("decoding public key: %w", err)
	}
	if len(pkBytes) != 48 {
		return nil, fmt.Errorf("expected 48-byte public key, got %d", len(pkBytes))
	}
	b.pkBytes = pkBytes

	return b, nil
}

// authenticate configures the Vault client token via the selected auth method.
func authenticate(client *vault.Client, cfg signerconfig.VaultConfig) error {
	switch cfg.AuthMethod {
	case "token", "":
		if cfg.Token == "" {
			return fmt.Errorf("auth_method=token requires vault.token to be set")
		}
		client.SetToken(cfg.Token)
		return nil

	case "kubernetes":
		jwtPath := cfg.KubernetesJWTPath
		if jwtPath == "" {
			jwtPath = defaultKubernetesJWTPath
		}
		jwt, err := os.ReadFile(jwtPath)
		if err != nil {
			return fmt.Errorf("reading kubernetes JWT from %q: %w", jwtPath, err)
		}
		k8sAuth, err := auth.NewKubernetesAuth(cfg.KubernetesRole,
			auth.WithServiceAccountToken(string(jwt)),
		)
		if err != nil {
			return fmt.Errorf("creating kubernetes auth: %w", err)
		}
		secret, err := client.Auth().Login(context.Background(), k8sAuth)
		if err != nil {
			return fmt.Errorf("kubernetes auth login: %w", err)
		}
		if secret == nil || secret.Auth == nil {
			return fmt.Errorf("kubernetes auth returned no token")
		}
		client.SetToken(secret.Auth.ClientToken)
		return nil

	case "aws-iam":
		return fmt.Errorf("aws-iam auth not yet implemented — use token or kubernetes")

	default:
		return fmt.Errorf("unknown auth_method %q — valid options: token, kubernetes, aws-iam", cfg.AuthMethod)
	}
}

// fetchPublicKey reads the compressed public key from the Vault plugin.
func (b *Backend) fetchPublicKey(ctx context.Context) (string, error) {
	path := fmt.Sprintf("%s/keys/%s/public-key", b.mountPath, b.keyName)
	secret, err := b.client.Logical().ReadWithContext(ctx, path)
	if err != nil {
		return "", fmt.Errorf("Vault read %s: %w", path, err)
	}
	if secret == nil || secret.Data == nil {
		return "", fmt.Errorf("Vault returned empty response for %s", path)
	}
	pkHex, ok := secret.Data["public_key"].(string)
	if !ok {
		return "", fmt.Errorf("unexpected public_key type in Vault response")
	}
	return pkHex, nil
}

// PublicKey returns the cached 48-byte compressed BLS public key.
func (b *Backend) PublicKey(_ context.Context) ([]byte, error) {
	return b.pkBytes, nil
}

// Sign requests a BLS signature from the Vault plugin using the Warp DST.
func (b *Backend) Sign(ctx context.Context, msg []byte) ([]byte, error) {
	return b.requestSign(ctx, hex.EncodeToString(msg), dstSign, "sign")
}

// SignProofOfPossession requests a BLS signature using the PoP DST.
func (b *Backend) SignProofOfPossession(ctx context.Context, msg []byte) ([]byte, error) {
	return b.requestSign(ctx, hex.EncodeToString(msg), dstPopProve, "sign-pop")
}

func (b *Backend) requestSign(ctx context.Context, msgHex, dstHex, endpoint string) ([]byte, error) {
	path := fmt.Sprintf("%s/keys/%s/%s", b.mountPath, b.keyName, endpoint)
	data := map[string]interface{}{
		"message": msgHex,
		"dst":     dstHex,
	}
	secret, err := b.client.Logical().WriteWithContext(ctx, path, data)
	if err != nil {
		return nil, fmt.Errorf("Vault write %s: %w", path, err)
	}
	if secret == nil || secret.Data == nil {
		return nil, fmt.Errorf("Vault returned empty response for %s", path)
	}
	sigHex, ok := secret.Data["signature"].(string)
	if !ok {
		return nil, fmt.Errorf("unexpected signature type in Vault response")
	}
	sigBytes, err := hex.DecodeString(sigHex)
	if err != nil {
		return nil, fmt.Errorf("decoding signature: %w", err)
	}
	if len(sigBytes) != 96 {
		return nil, fmt.Errorf("expected 96-byte signature, got %d", len(sigBytes))
	}
	return sigBytes, nil
}

// Close is a no-op for the Vault backend — no key material to zero.
func (b *Backend) Close() error {
	return nil
}
