//go:build linux

// Copyright (C) 2024, Ava Labs, Inc. All rights reserved.
// See the file LICENSE for licensing terms.

// Package awsnitro implements the Backend interface using an AWS Nitro Enclave.
//
// At startup the enclave process is launched from a pre-built .eif image.
// The enclave decrypts the BLS key using AWS KMS with attestation — the KMS
// key policy requires the decryption to come from this specific enclave image,
// so the plaintext key is only ever accessible inside the enclave.
//
// The host communicates with the enclave over vsock.  All signing operations
// happen inside the enclave; the host only sends messages and receives
// signatures.  The plaintext BLS key never crosses the enclave boundary.
package awsnitro

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net"
	"os/exec"
	"time"

	"github.com/mdlayher/vsock"

	signerconfig "github.com/ava-labs/avalanche-kms-signer/config"
	enclaveproto "github.com/ava-labs/avalanche-kms-signer/internal/enclaveproto"
)

// Backend communicates with the Nitro Enclave over vsock.
// No key material is held by the host process.
type Backend struct {
	enclaveCID uint32 // vsock CID assigned to the running enclave
	pkBytes    []byte // cached compressed public key (48 bytes)
	cmd        *exec.Cmd
	log        *slog.Logger
}

// New launches the enclave from the .eif image specified in cfg, waits for it
// to boot, fetches the public key, and returns a Backend ready for signing.
func New(cfg signerconfig.AWSNitroConfig, log *slog.Logger) (*Backend, error) {
	if log == nil {
		log = slog.Default()
	}

	log.Info("starting Nitro Enclave",
		"eif", cfg.EIFPath,
		"cpus", cfg.CPUCount,
		"memory_mb", cfg.MemoryMiB,
	)

	// Launch the enclave using nitro-cli.
	cmd := exec.Command("nitro-cli", "run-enclave",
		"--eif-path", cfg.EIFPath,
		"--cpu-count", fmt.Sprintf("%d", cfg.CPUCount),
		"--memory", fmt.Sprintf("%d", cfg.MemoryMiB),
		"--enclave-cid", fmt.Sprintf("%d", cfg.EnclaveCID),
	)
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("nitro-cli run-enclave: %w\noutput: %s", err, out)
	}

	log.Info("enclave started", "cid", cfg.EnclaveCID)

	b := &Backend{
		enclaveCID: cfg.EnclaveCID,
		log:        log,
	}

	// Wait for the enclave to boot and be ready to accept vsock connections.
	if err := b.waitForEnclave(30 * time.Second); err != nil {
		return nil, fmt.Errorf("waiting for enclave: %w", err)
	}

	// Fetch and cache the public key.
	pkBytes, err := b.fetchPublicKey()
	if err != nil {
		return nil, fmt.Errorf("fetching public key from enclave: %w", err)
	}
	if len(pkBytes) != 48 {
		return nil, fmt.Errorf("expected 48-byte public key, got %d", len(pkBytes))
	}
	b.pkBytes = pkBytes

	log.Info("enclave ready",
		"public_key_len", len(pkBytes),
	)

	return b, nil
}

// waitForEnclave polls the enclave vsock port until it responds or the timeout
// expires.
func (b *Backend) waitForEnclave(timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		conn, err := b.dial()
		if err == nil {
			conn.Close()
			return nil
		}
		time.Sleep(500 * time.Millisecond)
	}
	return fmt.Errorf("enclave did not become ready within %s", timeout)
}

// dial opens a vsock connection to the enclave.
func (b *Backend) dial() (net.Conn, error) {
	return vsock.Dial(b.enclaveCID, enclaveproto.VSockPort, nil)
}

// send sends a request to the enclave and returns the response.
func (b *Backend) send(req enclaveproto.Request) (enclaveproto.Response, error) {
	conn, err := b.dial()
	if err != nil {
		return enclaveproto.Response{}, fmt.Errorf("vsock dial: %w", err)
	}
	defer conn.Close()

	if err := json.NewEncoder(conn).Encode(req); err != nil {
		return enclaveproto.Response{}, fmt.Errorf("encoding request: %w", err)
	}

	var resp enclaveproto.Response
	if err := json.NewDecoder(conn).Decode(&resp); err != nil {
		return enclaveproto.Response{}, fmt.Errorf("decoding response: %w", err)
	}
	if resp.Error != "" {
		return enclaveproto.Response{}, fmt.Errorf("enclave error: %s", resp.Error)
	}
	return resp, nil
}

// fetchPublicKey requests the compressed BLS public key from the enclave.
func (b *Backend) fetchPublicKey() ([]byte, error) {
	resp, err := b.send(enclaveproto.Request{Type: enclaveproto.RequestPublicKey})
	if err != nil {
		return nil, err
	}
	return resp.Result, nil
}

// PublicKey returns the cached 48-byte compressed BLS public key.
func (b *Backend) PublicKey(_ context.Context) ([]byte, error) {
	return b.pkBytes, nil
}

// Sign requests a BLS signature from the enclave using the Warp DST.
func (b *Backend) Sign(_ context.Context, msg []byte) ([]byte, error) {
	resp, err := b.send(enclaveproto.Request{
		Type:    enclaveproto.RequestSign,
		Message: msg,
	})
	if err != nil {
		return nil, err
	}
	if len(resp.Result) != 96 {
		return nil, fmt.Errorf("expected 96-byte signature, got %d", len(resp.Result))
	}
	return resp.Result, nil
}

// SignProofOfPossession requests a BLS proof-of-possession signature from the
// enclave.
func (b *Backend) SignProofOfPossession(_ context.Context, msg []byte) ([]byte, error) {
	resp, err := b.send(enclaveproto.Request{
		Type:    enclaveproto.RequestSignPoP,
		Message: msg,
	})
	if err != nil {
		return nil, err
	}
	if len(resp.Result) != 96 {
		return nil, fmt.Errorf("expected 96-byte signature, got %d", len(resp.Result))
	}
	return resp.Result, nil
}

// Close terminates the enclave process.
func (b *Backend) Close() error {
	b.log.Info("terminating enclave")
	out, err := exec.Command("nitro-cli", "terminate-enclave",
		"--enclave-cid", fmt.Sprintf("%d", b.enclaveCID),
	).Output()
	if err != nil {
		return fmt.Errorf("nitro-cli terminate-enclave: %w\noutput: %s", err, out)
	}
	return nil
}
