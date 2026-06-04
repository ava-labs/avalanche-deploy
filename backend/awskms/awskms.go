// Copyright (C) 2024, Ava Labs, Inc. All rights reserved.
// See the file LICENSE for licensing terms.

// Package awskms implements the Backend interface using AWS KMS envelope
// encryption.  At startup it decrypts the encrypted BLS key blob from disk
// using AWS KMS and holds the plaintext key in memory for signing.
//
// Blob format: raw KMS ciphertext (output of kms:Encrypt on the 32-byte
// serialised BLS scalar).  The KMS key ID is stored in config, not in the
// blob itself.
package awskms

import (
	"context"
	"fmt"
	"log/slog"
	"os"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/kms"
	"github.com/aws/aws-sdk-go-v2/service/kms/types"

	signerconfig "github.com/ava-labs/avalanche-kms-signer/config"
	"github.com/ava-labs/avalanche-kms-signer/internal/blstcgo"
)

// kmsDecryptor is the subset of the KMS client used at runtime so tests can
// inject a mock without pulling in a real AWS connection.
type kmsDecryptor interface {
	Decrypt(ctx context.Context, in *kms.DecryptInput, opts ...func(*kms.Options)) (*kms.DecryptOutput, error)
}

// kmsEncryptor is the subset used by keytool helpers.
type kmsEncryptor interface {
	Encrypt(ctx context.Context, in *kms.EncryptInput, opts ...func(*kms.Options)) (*kms.EncryptOutput, error)
}

// Backend holds a BLS secret key decrypted from an AWS KMS-protected blob.
type Backend struct {
	skBytes []byte
	pkBytes []byte
	log     *slog.Logger
}

// Domain separation tags — must match AvalancheGo exactly.
var (
	dstSign     = []byte("BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_NUL_")
	dstPopProve = []byte("BLS_POP_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_")
)

// New loads and decrypts the BLS key from disk using AWS KMS.
func New(cfg signerconfig.AWSConfig, log *slog.Logger) (*Backend, error) {
	client, err := NewKMSClient(cfg)
	if err != nil {
		return nil, err
	}
	return newWithClient(cfg, log, client)
}

func newWithClient(cfg signerconfig.AWSConfig, log *slog.Logger, client kmsDecryptor) (*Backend, error) {
	ciphertext, err := os.ReadFile(cfg.EncryptedBLSKeyPath)
	if err != nil {
		return nil, fmt.Errorf("reading encrypted key %q: %w", cfg.EncryptedBLSKeyPath, err)
	}

	resp, err := client.Decrypt(context.Background(), &kms.DecryptInput{
		KeyId:               aws.String(cfg.KMSKeyID),
		CiphertextBlob:      ciphertext,
		EncryptionAlgorithm: types.EncryptionAlgorithmSpecSymmetricDefault,
	})
	if err != nil {
		return nil, fmt.Errorf("KMS decrypt: %w", err)
	}

	return backendFromBytes(resp.Plaintext, log)
}

func backendFromBytes(skBytes []byte, log *slog.Logger) (*Backend, error) {
	if len(skBytes) != blstcgo.SecretKeySize {
		return nil, fmt.Errorf("expected %d-byte BLS scalar, got %d bytes", blstcgo.SecretKeySize, len(skBytes))
	}
	if !blstcgo.ValidateSecretKey(skBytes) {
		return nil, fmt.Errorf("invalid BLS key material — not a valid scalar")
	}
	pkBytes, err := blstcgo.PublicKey(skBytes)
	if err != nil {
		return nil, fmt.Errorf("BLS public key derivation: %w", err)
	}
	return &Backend{skBytes: skBytes, pkBytes: pkBytes, log: log}, nil
}

// PublicKey returns the 48-byte compressed BLS public key.
func (b *Backend) PublicKey(_ context.Context) ([]byte, error) {
	return b.pkBytes, nil
}

// Sign produces a BLS signature over msg using the Warp message DST.
func (b *Backend) Sign(_ context.Context, msg []byte) ([]byte, error) {
	return blstcgo.Sign(b.skBytes, msg, dstSign)
}

// SignProofOfPossession produces a BLS signature over msg using the PoP DST.
func (b *Backend) SignProofOfPossession(_ context.Context, msg []byte) ([]byte, error) {
	return blstcgo.Sign(b.skBytes, msg, dstPopProve)
}

// Close zeroes the in-memory key material.
func (b *Backend) Close() error {
	for i := range b.skBytes {
		b.skBytes[i] = 0
	}
	return nil
}

// Encrypt encrypts plaintext using AWS KMS and returns the ciphertext blob.
// Used by keytool; not part of the Backend interface.
func Encrypt(ctx context.Context, client kmsEncryptor, keyID string, plaintext []byte) ([]byte, error) {
	resp, err := client.Encrypt(ctx, &kms.EncryptInput{
		KeyId:               aws.String(keyID),
		Plaintext:           plaintext,
		EncryptionAlgorithm: types.EncryptionAlgorithmSpecSymmetricDefault,
	})
	if err != nil {
		return nil, fmt.Errorf("KMS encrypt: %w", err)
	}
	return resp.CiphertextBlob, nil
}

// NewKMSClient builds a KMS client from config.  Exported for keytool.
// If cfg.EndpointURL is set, requests are routed there using static
// credentials — suitable for LocalStack and other local test environments.
func NewKMSClient(cfg signerconfig.AWSConfig) (*kms.Client, error) {
	opts := []func(*awsconfig.LoadOptions) error{
		awsconfig.WithRegion(cfg.Region),
	}

	// When a custom endpoint is set (e.g. LocalStack), bypass the normal
	// credential chain and use static credentials so the SDK doesn't attempt
	// STS validation against real AWS.
	if cfg.EndpointURL != "" {
		opts = append(opts, awsconfig.WithCredentialsProvider(
			credentials.NewStaticCredentialsProvider("test", "test", ""),
		))
	}

	awsCfg, err := awsconfig.LoadDefaultConfig(context.Background(), opts...)
	if err != nil {
		return nil, fmt.Errorf("loading AWS config: %w", err)
	}

	return kms.NewFromConfig(awsCfg, func(o *kms.Options) {
		if cfg.EndpointURL != "" {
			o.BaseEndpoint = aws.String(cfg.EndpointURL)
		}
	}), nil
}
