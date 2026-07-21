// Copyright (C) 2024, Ava Labs, Inc. All rights reserved.
// See the file LICENSE for licensing terms.

// Package gcpkms implements the Backend interface using Google Cloud KMS.
package gcpkms

import (
	"context"
	"encoding/hex"
	"fmt"
	"log/slog"
	"os"

	kms "cloud.google.com/go/kms/apiv1"
	kmspb "cloud.google.com/go/kms/apiv1/kmspb"
	gax "github.com/googleapis/gax-go/v2"

	signerconfig "github.com/ava-labs/avalanche-remote-signer/config"
	"github.com/ava-labs/avalanche-remote-signer/internal/blstutil"
)

// Domain separation tags — single source of truth in blstutil,
// cross-checked against AvalancheGo by the tests/ module.
var (
	dstSign     = blstutil.DSTSign
	dstPopProve = blstutil.DSTPoP
)

type kmsClient interface {
	Decrypt(ctx context.Context, req *kmspb.DecryptRequest, opts ...gax.CallOption) (*kmspb.DecryptResponse, error)
	Encrypt(ctx context.Context, req *kmspb.EncryptRequest, opts ...gax.CallOption) (*kmspb.EncryptResponse, error)
	Close() error
}

// Backend holds a BLS secret key decrypted from a GCP KMS-protected blob.
type Backend struct {
	skBytes []byte
	pkBytes []byte
	client  kmsClient
}

func resourceName(cfg signerconfig.GCPConfig) string {
	return fmt.Sprintf("projects/%s/locations/%s/keyRings/%s/cryptoKeys/%s",
		cfg.Project, cfg.Location, cfg.KeyRing, cfg.KeyName)
}

// New loads and decrypts the BLS key from disk using GCP KMS.
func New(cfg signerconfig.GCPConfig, log *slog.Logger) (*Backend, error) {
	client, err := kms.NewKeyManagementClient(context.Background())
	if err != nil {
		return nil, fmt.Errorf("creating GCP KMS client: %w", err)
	}
	b, err := newWithClient(cfg, log, client)
	if err != nil {
		// newWithClient only wires b.client on success — close it here so a
		// decrypt/read failure doesn't leak the client's gRPC connections.
		client.Close()
		return nil, err
	}
	return b, nil
}

func newWithClient(cfg signerconfig.GCPConfig, log *slog.Logger, client kmsClient) (*Backend, error) {
	ciphertext, err := os.ReadFile(cfg.EncryptedBLSKeyPath)
	if err != nil {
		return nil, fmt.Errorf("reading encrypted key %q: %w", cfg.EncryptedBLSKeyPath, err)
	}

	resp, err := client.Decrypt(context.Background(), &kmspb.DecryptRequest{
		Name:       resourceName(cfg),
		Ciphertext: ciphertext,
	})
	if err != nil {
		return nil, fmt.Errorf("GCP KMS decrypt: %w", err)
	}

	b, err := backendFromBytes(resp.Plaintext, log)
	if err != nil {
		return nil, err
	}
	b.client = client
	return b, nil
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
	// Log the loaded identity so an operator can confirm it against the
	// on-chain registration (public keys are public — safe to log).
	if log != nil {
		log.Info("gcp-kms backend initialized", "public_key", hex.EncodeToString(pkBytes))
	}
	return &Backend{skBytes: skBytes, pkBytes: pkBytes}, nil
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
	if b.client != nil {
		return b.client.Close()
	}
	return nil
}

// Encrypt encrypts plaintext using GCP KMS. Used by keytool.
func Encrypt(ctx context.Context, client kmsClient, keyName string, plaintext []byte) ([]byte, error) {
	resp, err := client.Encrypt(ctx, &kmspb.EncryptRequest{
		Name:      keyName,
		Plaintext: plaintext,
	})
	if err != nil {
		return nil, fmt.Errorf("GCP KMS encrypt: %w", err)
	}
	return resp.Ciphertext, nil
}

// NewKMSClient builds a production GCP KMS client. Exported for keytool.
func NewKMSClient(ctx context.Context) (*kms.KeyManagementClient, error) {
	client, err := kms.NewKeyManagementClient(ctx)
	if err != nil {
		return nil, fmt.Errorf("creating GCP KMS client: %w", err)
	}
	return client, nil
}
