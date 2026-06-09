//go:build linux

// Copyright (C) 2024, Ava Labs, Inc. All rights reserved.
// See the file LICENSE for licensing terms.

// Package awsnitro implements the Backend interface using an AWS Nitro Enclave.
//
// The host launches the enclave, sends it temporary AWS credentials over vsock
// (the enclave has no IMDS access), and then receives the derived BLS public
// key.  All subsequent signing operations happen inside the enclave — the BLS
// plaintext key never crosses the enclave boundary.
package awsnitro

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net"
	"os/exec"
	"strings"
	"time"

	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/mdlayher/vsock"

	signerconfig "github.com/ava-labs/avalanche-kms-signer/config"
	enclaveproto "github.com/ava-labs/avalanche-kms-signer/internal/enclaveproto"
)

// Backend communicates with the Nitro Enclave over vsock.
type Backend struct {
	enclaveCID uint32
	pkBytes    []byte
	log        *slog.Logger
}

// New launches the enclave, sends AWS credentials, waits for the public key,
// and returns a Backend ready for signing.
func New(cfg signerconfig.AWSNitroConfig, log *slog.Logger) (*Backend, error) {
	if log == nil {
		log = slog.Default()
	}

	log.Info("starting Nitro Enclave",
		"eif", cfg.EIFPath,
		"cpus", cfg.CPUCount,
		"memory_mb", cfg.MemoryMiB,
	)

	// Check if an enclave is already running with the target CID.
	// This handles the case where remote-signer crashed and restarted while the
	// enclave kept running — we reconnect instead of launching a new one.
	if enclaveRunning(cfg.EnclaveCID) {
		log.Info("enclave already running, reconnecting", "cid", cfg.EnclaveCID)
	} else {
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
	}

	b := &Backend{enclaveCID: cfg.EnclaveCID, log: log}

	var pkBytes []byte

	if enclaveRunning(cfg.EnclaveCID) && isEnclaveReady(cfg.EnclaveCID) {
		// Enclave is already running and the signing port is open — skip init
		// and just fetch the public key.  This handles remote-signer restarts.
		log.Info("enclave already initialized, fetching public key", "cid", cfg.EnclaveCID)
		var err error
		pkBytes, err = b.fetchPublicKey()
		if err != nil {
			return nil, fmt.Errorf("fetching public key from running enclave: %w", err)
		}
	} else {
		// Fresh start — send credentials and wait for the enclave to decrypt the key.
		initMsg, err := b.buildInitMessage(cfg)
		if err != nil {
			return nil, fmt.Errorf("getting AWS credentials: %w", err)
		}
		pkBytes, err = b.sendInitWithRetry(initMsg, 30*time.Second)
		if err != nil {
			return nil, fmt.Errorf("enclave init: %w", err)
		}
	}

	if len(pkBytes) != 48 {
		return nil, fmt.Errorf("expected 48-byte public key, got %d", len(pkBytes))
	}
	b.pkBytes = pkBytes

	log.Info("enclave ready")
	return b, nil
}

// buildInitMessage gets temporary AWS credentials from the instance profile.
func (b *Backend) buildInitMessage(cfg signerconfig.AWSNitroConfig) (enclaveproto.InitMessage, error) {
	awsCfg, err := awsconfig.LoadDefaultConfig(context.Background(),
		awsconfig.WithRegion(cfg.Region),
	)
	if err != nil {
		return enclaveproto.InitMessage{}, fmt.Errorf("loading AWS config: %w", err)
	}

	creds, err := awsCfg.Credentials.Retrieve(context.Background())
	if err != nil {
		return enclaveproto.InitMessage{}, fmt.Errorf("retrieving credentials: %w", err)
	}

	return enclaveproto.InitMessage{
		AccessKeyID:     creds.AccessKeyID,
		SecretAccessKey: creds.SecretAccessKey,
		SessionToken:    creds.SessionToken,
		Region:          cfg.Region,
	}, nil
}

// isEnclaveReady returns true if the enclave's signing port (5000) is accepting
// connections, meaning the enclave has already been initialized with credentials.
func isEnclaveReady(cid uint32) bool {
	conn, err := vsock.Dial(cid, enclaveproto.VSockPort, nil)
	if err != nil {
		return false
	}
	conn.Close()
	return true
}

// enclaveRunning returns true if an enclave with the given CID is already running.
func enclaveRunning(cid uint32) bool {
	out, err := exec.Command("nitro-cli", "describe-enclaves").Output()
	if err != nil {
		return false
	}
	return strings.Contains(string(out), fmt.Sprintf(`"EnclaveCID": %d`, cid))
}

// sendInitWithRetry retries sendInit until it succeeds or the timeout expires.
func (b *Backend) sendInitWithRetry(msg enclaveproto.InitMessage, timeout time.Duration) ([]byte, error) {
	deadline := time.Now().Add(timeout)
	var lastErr error
	for time.Now().Before(deadline) {
		pkBytes, err := b.sendInit(msg)
		if err == nil {
			return pkBytes, nil
		}
		lastErr = err
		b.log.Debug("enclave not ready yet, retrying...", "err", err)
		time.Sleep(500 * time.Millisecond)
	}
	return nil, fmt.Errorf("timed out after %s: %w", timeout, lastErr)
}

// sendInit sends credentials to the enclave and returns the BLS public key.
func (b *Backend) sendInit(msg enclaveproto.InitMessage) ([]byte, error) {
	conn, err := vsock.Dial(b.enclaveCID, enclaveproto.VSockInitPort, nil)
	if err != nil {
		return nil, fmt.Errorf("vsock dial init port: %w", err)
	}
	defer conn.Close()

	if err := json.NewEncoder(conn).Encode(msg); err != nil {
		return nil, fmt.Errorf("sending init message: %w", err)
	}

	var resp enclaveproto.InitResponse
	if err := json.NewDecoder(conn).Decode(&resp); err != nil {
		return nil, fmt.Errorf("decoding init response: %w", err)
	}
	if resp.Error != "" {
		return nil, fmt.Errorf("enclave init error: %s", resp.Error)
	}

	pkBytes, err := hexDecode(resp.PublicKey)
	if err != nil {
		return nil, fmt.Errorf("decoding public key: %w", err)
	}
	return pkBytes, nil
}

// waitForPort polls a vsock port until it's reachable or the timeout expires.
func (b *Backend) waitForPort(port uint32, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		conn, err := vsock.Dial(b.enclaveCID, port, nil)
		if err == nil {
			conn.Close()
			return nil
		}
		time.Sleep(500 * time.Millisecond)
	}
	return fmt.Errorf("enclave port %d not ready within %s", port, timeout)
}

// dial opens a vsock connection to the enclave's signing port.
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

// fetchPublicKey requests the BLS public key from the enclave's signing port.
func (b *Backend) fetchPublicKey() ([]byte, error) {
	resp, err := b.send(enclaveproto.Request{Type: enclaveproto.RequestPublicKey})
	if err != nil {
		return nil, err
	}
	return resp.Result, nil
}

// PublicKey returns the cached BLS public key.
func (b *Backend) PublicKey(_ context.Context) ([]byte, error) { return b.pkBytes, nil }

// Sign requests a BLS signature from the enclave using the Warp DST.
func (b *Backend) Sign(_ context.Context, msg []byte) ([]byte, error) {
	resp, err := b.send(enclaveproto.Request{Type: enclaveproto.RequestSign, Message: msg})
	if err != nil {
		return nil, err
	}
	if len(resp.Result) != 96 {
		return nil, fmt.Errorf("expected 96-byte signature, got %d", len(resp.Result))
	}
	return resp.Result, nil
}

// SignProofOfPossession requests a BLS PoP signature from the enclave.
func (b *Backend) SignProofOfPossession(_ context.Context, msg []byte) ([]byte, error) {
	resp, err := b.send(enclaveproto.Request{Type: enclaveproto.RequestSignPoP, Message: msg})
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

func hexDecode(s string) ([]byte, error) {
	if len(s) == 0 {
		return nil, fmt.Errorf("empty hex string")
	}
	out := make([]byte, len(s)/2)
	for i := 0; i < len(s)-1; i += 2 {
		var b byte
		if _, err := fmt.Sscanf(s[i:i+2], "%02x", &b); err != nil {
			return nil, fmt.Errorf("invalid hex at position %d: %w", i, err)
		}
		out[i/2] = b
	}
	return out, nil
}
