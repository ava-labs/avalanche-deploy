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
// This backend renews renewable tokens before they expire, replaces
// non-renewable dynamic tokens (e.g. batch tokens) with a fresh login, and
// re-authenticates with backoff on failure.  A validator running for weeks
// will not lose signing capability due to token expiry — with one exception:
// a static token (auth_method=token) that is itself non-renewable cannot be
// kept alive, and the signer logs a loud warning at startup in that case.
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

	signerconfig "github.com/ava-labs/avalanche-deploy/tools/remote-signer/config"
	"github.com/ava-labs/avalanche-deploy/tools/remote-signer/internal/blstutil"
)

// Domain separation tags — single source of truth in blstutil,
// cross-checked against AvalancheGo by the tests/ module.
var (
	dstSign     = hex.EncodeToString(blstutil.DSTSign)
	dstPopProve = hex.EncodeToString(blstutil.DSTPoP)
)

const (
	defaultMountPath         = "bls"
	defaultKubernetesJWTPath = "/var/run/secrets/kubernetes.io/serviceaccount/token"
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

	// Start background token maintenance.  Tokens for Kubernetes auth (and
	// other dynamic auth methods) expire; without renewal the signer would
	// stop working after the TTL.  Renewable tokens are renewed, non-renewable
	// dynamic tokens (e.g. batch tokens) are replaced by a fresh login, and
	// never-expiring tokens (root) are detected and skipped.  A static
	// non-renewable token cannot be kept alive — that case logs a loud
	// warning at startup.
	go b.renewTokenLoop(ctx)

	return b, nil
}

// tokenAction is what the renewal loop should do with the current token,
// decided from its TTL, renewability, and the configured auth method.
type tokenAction int

const (
	// tokenActionNone: the token never expires (lookup-self reports no
	// expire_time) — no renewal needed, the loop can exit.
	tokenActionNone tokenAction = iota
	// tokenActionStop: the token expires and cannot be refreshed — a static
	// token (auth_method=token) that is non-renewable. Re-login would just
	// re-install the same token, so warn loudly and exit.
	tokenActionStop
	// tokenActionRenew: renewable — RenewSelf at renewFraction of the TTL.
	tokenActionRenew
	// tokenActionReauth: non-renewable but issued by a dynamic auth method
	// (e.g. a batch token from a kubernetes/aws-iam role with
	// token_type=batch) — renewal is impossible by definition, so log in
	// again for a fresh token at renewFraction of the TTL.
	tokenActionReauth
)

// classifyToken decides from lookup-self facts. "Never expires" is judged by
// the expires flag (expire_time present in lookup-self), NOT by ttl == 0:
// Vault reports TTL in whole seconds rounded down, so a live expiring token in
// its final sub-second also reads ttl=0 — classifying on TTL would exit the
// renewal loop permanently for a token that very much needs refreshing.
func classifyToken(expires, renewable bool, authMethod string) tokenAction {
	switch {
	case !expires:
		return tokenActionNone
	case renewable:
		return tokenActionRenew
	case authMethod == "token" || authMethod == "":
		return tokenActionStop
	default:
		return tokenActionReauth
	}
}

// renewTokenLoop runs in a background goroutine, keeping the Vault token
// valid: renewable tokens are renewed, non-renewable dynamic tokens are
// replaced by a fresh login, and failures re-authenticate with backoff.
func (b *Backend) renewTokenLoop(ctx context.Context) {
	for {
		ttl, renewable, expires, err := b.tokenTTL()
		if err != nil {
			// A failed lookup usually means the token has expired or been
			// revoked — renewal cannot recover that, only a fresh login can.
			// Re-authenticate here; otherwise an expired token wedges this
			// loop (and therefore all signing) permanently, since the renewal
			// path below is only reachable after a successful lookup.
			b.logf("warn", "Vault token lookup failed, re-authenticating", "err", err)
			if authErr := authenticate(b.client, b.cfg); authErr != nil {
				b.logf("error", "Vault re-authentication failed", "err", authErr)
			} else {
				b.logf("info", "Vault re-authentication successful")
			}
			// Back off before the next lookup regardless of the auth outcome.
			// For auth_method=token, authenticate just re-installs the same
			// static token and always "succeeds" — without this backoff an
			// expired static token would spin this loop unthrottled,
			// hammering Vault with lookups and flooding the logs.
			select {
			case <-ctx.Done():
				return
			case <-time.After(30 * time.Second):
			}
			continue
		}

		switch classifyToken(expires, renewable, b.cfg.AuthMethod) {
		case tokenActionNone:
			b.logf("debug", "Vault token does not expire — renewal not needed")
			return
		case tokenActionStop:
			b.logf("warn", "static Vault token is non-renewable and will expire — "+
				"signing will fail once the TTL lapses; supply a renewable token "+
				"(vault token create without -type=batch and with a policy allowing renew-self)",
				"ttl", ttl)
			return
		}

		// Sleep until renewFraction of the TTL has elapsed. A nearly-expired
		// token (ttl rounding down to 0) sleeps 0s — an immediate refresh,
		// which is exactly what it needs.
		sleepFor := time.Duration(float64(ttl) * renewFraction)
		b.logf("debug", "Vault token refresh scheduled", "ttl", ttl, "refresh_in", sleepFor, "renewable", renewable)

		select {
		case <-ctx.Done():
			return
		case <-time.After(sleepFor):
		}

		if renewable {
			if _, err := b.client.Auth().Token().RenewSelf(0); err == nil {
				b.logf("debug", "Vault token renewed successfully")
				continue
			} else {
				b.logf("warn", "Vault token renewal failed, re-authenticating", "err", err)
			}
		}
		// Non-renewable dynamic token, or renewal just failed: log in again.
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
	}
}

// tokenTTL returns the remaining TTL, whether the token is renewable, and
// whether it expires at all (root/periodic-orphan tokens report no
// expire_time — that flag, not ttl==0, is the "never expires" signal).
func (b *Backend) tokenTTL() (time.Duration, bool, bool, error) {
	secret, err := b.client.Auth().Token().LookupSelf()
	if err != nil {
		return 0, false, false, err
	}
	ttl, err := secret.TokenTTL()
	if err != nil {
		return 0, false, false, err
	}
	renewable, err := secret.TokenIsRenewable()
	if err != nil {
		// Don't guess: treating a parse hiccup as "non-renewable" would
		// permanently disable renewal for a genuinely renewable token.
		return 0, false, false, fmt.Errorf("token renewable lookup: %w", err)
	}
	expires := secret.Data["expire_time"] != nil
	return ttl, renewable, expires, nil
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
	}
	// The sign-pop endpoint declares no "dst" field and always uses the PoP
	// DST; sending one draws an "unrecognized parameters: [dst]" warning on
	// every proof-of-possession. Only the generic /sign endpoint takes a dst.
	if endpoint == "sign" {
		data["dst"] = dstHex
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
