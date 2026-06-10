//go:build !linux

// Copyright (C) 2024, Ava Labs, Inc. All rights reserved.
// See the file LICENSE for licensing terms.

// Package awsnitro — stub for non-Linux platforms.
// Nitro Enclaves only run on Linux (EC2).  This stub allows the binary to
// compile on macOS and other platforms while returning a clear error if someone
// accidentally tries to use the backend outside of EC2.
package awsnitro

import (
	"context"
	"fmt"
	"log/slog"

	signerconfig "github.com/ava-labs/avalanche-remote-signer/config"
)

// Backend is a placeholder on non-Linux platforms.
type Backend struct{}

// New always returns an error on non-Linux platforms.
func New(_ signerconfig.AWSNitroConfig, _ *slog.Logger) (*Backend, error) {
	return nil, fmt.Errorf("aws-nitro backend is only supported on Linux (EC2 with Nitro Enclaves enabled)")
}

func (b *Backend) PublicKey(_ context.Context) ([]byte, error) { return nil, unsupported() }
func (b *Backend) Sign(_ context.Context, _ []byte) ([]byte, error) { return nil, unsupported() }
func (b *Backend) SignProofOfPossession(_ context.Context, _ []byte) ([]byte, error) {
	return nil, unsupported()
}
func (b *Backend) Close() error { return nil }

func unsupported() error {
	return fmt.Errorf("aws-nitro backend is only supported on Linux")
}
