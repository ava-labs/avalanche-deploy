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
//
// Token renewal: Vault tokens have a TTL (typically 1h for Kubernetes auth).
// This backend automatically renews the token before it expires and
// re-authenticates if renewal fails.  A validator running for weeks will
// never lose signing capability due to token expiry.
package vault

import (
	"context"
	"encoding/hex"
	"fmt"
	"log/slog"
	"os"
	"time"

	vault "github.com/hashicorp/vault/api"
	awsauth "github.com/hashicorp/vault/api/auth/aws"
	k8sauth "github.com/hashicorp/vault/api/auth/kubernetes"

	signerconfig "github.com/ava-labs/avalanche-remote-signer/config"
	"github.com/ava-labs/avalanche-remote-signer/internal/blstutil"
)

// Domain separation tags — single source of truth in blstutil,
// cross-checked against AvalancheGo by the tests in compat/.
var (
	dstSign     = hex.EncodeToString(blstutil.DSTSign)
	dstPopProve = hex.EncodeToString(blstutil.DSTPoP)
)

const (
	defaultMountPath          = "bls"
	defaultKubernetesJWTPath  = "/var/run/secrets/kubernetes.io/serviceaccount/token"
	// renewFraction is the fraction of the token TTL at which we renew.
	// 0.75 means renew at 75% of the TTL, leaving a 25% safety window.
	renewFraction = 0.75
)

// Backend holds a Vault client and the key path; no key material is stored here.
type Backend struct {
	client    *vault.Client
	cfg       signerconfig.VaultConfig
	mountPath string
	keyName   string
	pkBytes   []byte // cached compressed public key
	log       *slog.Logger
	cancel    context.CancelFunc
}

// New creates a Vault backend, authenticates, caches the public key, and
// starts background token renewal.
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

	ctx, cancel := context.WithCancel(context.Background())

	b := &Backend{
		client:    client,
		cfg:       cfg,
		mountPath: mountPath,
		keyName:   cfg.KeyName,
		log:       log,
		cancel:    cancel,
	}

	// Cache the public key at boot.
	pkHex, err := b.fetchPublicKey(context.Background())
	if err != nil {
		cancel()
		return nil, fmt.Errorf("fetching public key from Vault: %w", err)
	}
	pkBytes, err := hex.DecodeString(pkHex)
	if err != nil {
		cancel()
		return nil, fmt.Errorf("decoding public key: %w", err)
	}
	if len(pkBytes) != 48 {
		cancel()
		return nil, fmt.Errorf("expected 48-byte public key, got %d", len(pkBytes))
	}
	b.pkBytes = pkBytes

	// Start background token renewal.  Tokens for Kubernetes auth (and other
	// dynamic auth methods) expire; without renewal the signer would stop
	// working after the TTL.  Root tokens and non-renewable tokens are
	// detected and skipped automatically.
	go b.renewTokenLoop(ctx)

	return b, nil
}

// renewTokenLoop runs in a background goroutine, renewing the Vault token
// before it expires.  If renewal fails it re-authenticates from scratch.
func (b *Backend) renewTokenLoop(ctx context.Context) {
	for {
		ttl, renewable, err := b.tokenTTL()
		if err != nil {
			b.logf("warn", "could not look up Vault token TTL", "err", err)
			select {
			case <-ctx.Done():
				return
			case <-time.After(30 * time.Second):
				continue
			}
		}

		// Root tokens and non-expiring tokens don't need renewal.
		if !renewable || ttl <= 0 {
			b.logf("debug", "Vault token does not require renewal")
			return
		}

		// Sleep until renewFraction of the TTL has elapsed.
		sleepFor := time.Duration(float64(ttl) * renewFraction)
		b.logf("debug", "Vault token renewal scheduled", "ttl", ttl, "renew_in", sleepFor)

		select {
		case <-ctx.Done():
			return
		case <-time.After(sleepFor):
		}

		// Try to renew the current token.
		_, err = b.client.Auth().Token().RenewSelf(0)
		if err != nil {
			b.logf("warn", "Vault token renewal failed, re-authenticating", "err", err)
			if err := authenticate(b.client, b.cfg); err != nil {
				b.logf("error", "Vault re-authentication failed", "err", err)
				// Back off and try again next cycle.
				select {
				case <-ctx.Done():
					return
				case <-time.After(15 * time.Second):
				}
			} else {
				b.logf("info", "Vault re-authentication successful")
			}
		} else {
			b.logf("debug", "Vault token renewed successfully")
		}
	}
}

// tokenTTL returns the remaining TTL and whether the token is renewable.
func (b *Backend) tokenTTL() (time.Duration, bool, error) {
	secret, err := b.client.Auth().Token().LookupSelf()
	if err != nil {
		return 0, false, err
	}
	ttl, err := secret.TokenTTL()
	if err != nil {
		return 0, false, err
	}
	renewable, _ := secret.TokenIsRenewable()
	return ttl, renewable, nil
}

// logf logs at the given level if a logger is configured.
func (b *Backend) logf(level, msg string, args ...any) {
	if b.log == nil {
		return
	}
	switch level {
	case "error":
		b.log.Error(msg, args...)
	case "warn":
		b.log.Warn(msg, args...)
	case "info":
		b.log.Info(msg, args...)
	default:
		b.log.Debug(msg, args...)
	}
}

// authenticate configures the Vault client token via the selected auth method.
// For Kubernetes auth, the JWT is re-read from disk on every call so that
// rotated service account tokens are picked up automatically.
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
		// Re-read JWT from disk on every auth call — Kubernetes rotates
		// bound service account tokens periodically.
		jwt, err := os.ReadFile(jwtPath)
		if err != nil {
			return fmt.Errorf("reading kubernetes JWT from %q: %w", jwtPath, err)
		}
		k8sAuth, err := k8sauth.NewKubernetesAuth(cfg.KubernetesRole,
			k8sauth.WithServiceAccountToken(string(jwt)),
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
		// AWS IAM auth uses the standard AWS credential chain — env vars,
		// ~/.aws/credentials, EC2 instance profile, ECS task role, etc.
		// The vault/api/auth/aws package signs an STS GetCallerIdentity
		// request and sends it to Vault, which calls STS to verify identity.
		iamAuth, err := awsauth.NewAWSAuth(
			awsauth.WithRole(cfg.AWSRole),
		)
		if err != nil {
			return fmt.Errorf("creating AWS IAM auth: %w", err)
		}
		secret, err := client.Auth().Login(context.Background(), iamAuth)
		if err != nil {
			return fmt.Errorf("AWS IAM auth login: %w", err)
		}
		if secret == nil || secret.Auth == nil {
			return fmt.Errorf("AWS IAM auth returned no token")
		}
		client.SetToken(secret.Auth.ClientToken)
		return nil

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

// Close stops the token renewal goroutine.
func (b *Backend) Close() error {
	if b.cancel != nil {
		b.cancel()
	}
	return nil
}
