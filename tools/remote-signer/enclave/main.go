// Copyright (C) 2024, Ava Labs, Inc. All rights reserved.
// See the file LICENSE for licensing terms.

// enclave/main.go runs inside the AWS Nitro Enclave.
//
// Startup sequence:
//  1. Listen on vsock port 5001 for an InitMessage from the host.
//     The host sends temporary AWS credentials (from its IMDS role) and the
//     KMS key ID.  Enclaves have no IMDS access so credentials must be injected.
//  2. Use those credentials to call KMS Decrypt via the vsock proxy on the host
//     (CID 3, port 8443 → kms.<region>.amazonaws.com:443).
//  3. Deserialize the decrypted BLS key and hold it in memory.
//  4. Reply with the public key on the init connection.
//  5. Listen on vsock port 5000 for sign/public-key requests.

package main

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/kms"
	"github.com/aws/aws-sdk-go-v2/service/kms/types"
	"github.com/mdlayher/vsock"
	blst "github.com/supranational/blst/bindings/go"

	blstutil "github.com/ava-labs/avalanche-deploy/tools/remote-signer/internal/blstutil"
	enclaveproto "github.com/ava-labs/avalanche-deploy/tools/remote-signer/internal/enclaveproto"
)

// Domain separation tags come from blstutil — the single source of truth that
// the tests/ module cross-checks against AvalancheGo. Do not hand-copy them
// here; a drift between this enclave and the host backends is exactly the
// RO_NUL_/RO_POP_ failure that silently breaks every warp signature.

// hostCID is the vsock CID of the host — always 3 inside an enclave.
const hostCID = 3

// kmsProxyPort is the port vsock-proxy listens on for KMS traffic.
const kmsProxyPort = 8443

func main() {
	if len(os.Args) < 2 {
		log.Fatal("usage: enclave <encrypted-key-path>")
	}
	encryptedKeyPath := os.Args[1]

	ciphertext, err := os.ReadFile(encryptedKeyPath)
	if err != nil {
		log.Fatalf("reading encrypted key: %v", err)
	}

	// Step 1: wait for init message from host (credentials + KMS key ID).
	log.Printf("waiting for init message on vsock port %d...", enclaveproto.VSockInitPort)
	init, initConn, err := receiveInit()
	if err != nil {
		log.Fatalf("receiving init: %v", err)
	}

	// Step 2: decrypt BLS key via KMS through the vsock proxy on the host.
	skBytes, err := decryptKey(init, ciphertext)
	if err != nil {
		sendInitResponse(initConn, "", fmt.Sprintf("KMS decrypt: %v", err))
		log.Fatalf("KMS decrypt: %v", err)
	}

	// Step 3: deserialize and validate the BLS key.
	sk := new(blst.SecretKey)
	if sk.Deserialize(skBytes) == nil {
		zeroize(skBytes)
		sendInitResponse(initConn, "", "invalid BLS scalar")
		log.Fatal("invalid BLS scalar from KMS decrypt")
	}
	// sk now holds its own copy of the scalar (and must live for the life of
	// the process — it signs every request), so wipe the decrypted bytes
	// eagerly. A defer would never run: serve() blocks forever and every
	// error path is log.Fatal → os.Exit, which skips deferred calls.
	zeroize(skBytes)
	pk := new(blst.P1Affine).From(sk)
	pkHex := hex.EncodeToString(pk.Compress())

	log.Printf("BLS key decrypted successfully, public key: %s", pkHex)

	// Step 4: reply with public key on the init connection.
	sendInitResponse(initConn, pkHex, "")
	initConn.Close()

	// Step 5: serve signing requests on port 5000.
	if err := serve(sk, pk.Compress()); err != nil {
		log.Fatalf("vsock server: %v", err)
	}
}

// receiveInit listens on vsock port 5001 for the host's InitMessage.
// It keeps accepting connections until it receives a valid InitMessage, so
// that a probe connection doesn't consume the accept slot — whether the probe
// closes immediately (Decode fails fast) or just sits silent (the read
// deadline expires). Without the deadline one silent connection would park
// this single-threaded loop forever and the real InitMessage would never be
// accepted.
func receiveInit() (enclaveproto.InitMessage, net.Conn, error) {
	ln, err := vsock.Listen(enclaveproto.VSockInitPort, nil)
	if err != nil {
		return enclaveproto.InitMessage{}, nil, fmt.Errorf("vsock listen port %d: %w", enclaveproto.VSockInitPort, err)
	}
	defer ln.Close()

	for {
		conn, err := ln.Accept()
		if err != nil {
			return enclaveproto.InitMessage{}, nil, fmt.Errorf("accept: %w", err)
		}

		var msg enclaveproto.InitMessage
		// Cap the read at MaxMessageSize — the host is outside the trust
		// boundary, and an unbounded decode would let it OOM the enclave.
		_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
		if err := json.NewDecoder(io.LimitReader(conn, enclaveproto.MaxMessageSize)).Decode(&msg); err != nil {
			// Empty, invalid, or silent connection — close and wait for the
			// real one.
			conn.Close()
			continue
		}
		// Clear the deadline: the InitResponse is written on this connection
		// only after the KMS decrypt completes, which takes seconds.
		_ = conn.SetReadDeadline(time.Time{})

		return msg, conn, nil
	}
}

// sendInitResponse sends the public key (or error) back on the init connection.
func sendInitResponse(conn net.Conn, pkHex, errMsg string) {
	_ = json.NewEncoder(conn).Encode(enclaveproto.InitResponse{
		PublicKey: pkHex,
		Error:     errMsg,
	})
}

// vsockHTTPClient returns an HTTP client that routes all connections through
// the vsock proxy on the host (CID 3, port 8443).  vsock-proxy forwards to
// kms.<region>.amazonaws.com:443.  TLS is end-to-end — the SDK sets SNI from
// the request URL so certificates validate correctly.
func vsockHTTPClient() *http.Client {
	return &http.Client{
		// Bound every KMS request. Without this, a vsock-proxy that accepts
		// the connection but stalls would block Decrypt forever — and by then
		// the init listener is already closed, so the host can never re-init:
		// the enclave would sit as an unreachable zombie holding live AWS
		// credentials until someone terminates it with nitro-cli.
		Timeout: 30 * time.Second,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				return vsock.Dial(hostCID, kmsProxyPort, nil)
			},
		},
	}
}

// decryptKey calls AWS KMS via the vsock proxy on the host using the injected credentials.
func decryptKey(init enclaveproto.InitMessage, ciphertext []byte) ([]byte, error) {
	creds := credentials.NewStaticCredentialsProvider(
		init.AccessKeyID,
		init.SecretAccessKey,
		init.SessionToken,
	)

	cfg, err := config.LoadDefaultConfig(context.Background(),
		config.WithRegion(init.Region),
		config.WithCredentialsProvider(creds),
		config.WithHTTPClient(vsockHTTPClient()),
	)
	if err != nil {
		return nil, fmt.Errorf("AWS config: %w", err)
	}

	client := kms.NewFromConfig(cfg)

	// Read KMS key ID from the baked-in file.
	kmsKeyIDBytes, err := os.ReadFile("/kms-key-id.txt")
	if err != nil {
		return nil, fmt.Errorf("reading KMS key ID: %w", err)
	}
	kmsKeyID := strings.TrimSpace(string(kmsKeyIDBytes))

	// NOTE: this is a plain Decrypt with no Recipient attestation document, so
	// KMS authorizes it by IAM alone — it cannot distinguish this enclave from
	// any other caller holding the same credentials. Consequently the key
	// policy must NOT carry a kms:RecipientAttestation:* condition (it would
	// always deny). Wiring up NSM attestation + CiphertextForRecipient is the
	// documented hardening path — see docs/aws-nitro.md "Hardening roadmap".
	// Overall bound across the SDK's internal retries (the HTTP client's 30s
	// timeout bounds each attempt). On error, main reports it back to the
	// host on the init connection and exits — a clean failure, not a hang.
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	resp, err := client.Decrypt(ctx, &kms.DecryptInput{
		KeyId:               aws.String(kmsKeyID),
		CiphertextBlob:      ciphertext,
		EncryptionAlgorithm: types.EncryptionAlgorithmSpecSymmetricDefault,
	})
	if err != nil {
		return nil, fmt.Errorf("KMS Decrypt: %w", err)
	}

	if len(resp.Plaintext) != 32 {
		return nil, fmt.Errorf("expected 32-byte BLS scalar, got %d", len(resp.Plaintext))
	}
	return resp.Plaintext, nil
}

// serve listens on vsock port 5000 for sign/public-key requests from the host.
func serve(sk *blst.SecretKey, pkBytes []byte) error {
	ln, err := vsock.Listen(enclaveproto.VSockPort, nil)
	if err != nil {
		return fmt.Errorf("vsock listen port %d: %w", enclaveproto.VSockPort, err)
	}
	log.Printf("listening for signing requests on vsock port %d", enclaveproto.VSockPort)

	for {
		conn, err := ln.Accept()
		if err != nil {
			// Back off so a persistent Accept failure (e.g. FD exhaustion)
			// doesn't become a CPU-burning hot loop flooding the console.
			log.Printf("accept error: %v", err)
			time.Sleep(time.Second)
			continue
		}
		go handleConn(conn, sk, pkBytes)
	}
}

func handleConn(conn net.Conn, sk *blst.SecretKey, pkBytes []byte) {
	defer conn.Close()

	// One request/response per connection, bounded in time as well as size —
	// an idle connection must not park this goroutine and its FD forever.
	// Matches the host's enclaveRequestTimeout.
	_ = conn.SetDeadline(time.Now().Add(10 * time.Second))

	var req enclaveproto.Request
	// Cap the read at MaxMessageSize — the host is outside the trust boundary,
	// and an unbounded decode would let it OOM the enclave.
	if err := json.NewDecoder(io.LimitReader(conn, enclaveproto.MaxMessageSize)).Decode(&req); err != nil {
		writeError(conn, fmt.Sprintf("decode: %v", err))
		return
	}

	var resp enclaveproto.Response
	switch req.Type {
	case enclaveproto.RequestPublicKey:
		resp.Result = pkBytes
	case enclaveproto.RequestSign:
		sig := new(blst.P2Affine).Sign(sk, req.Message, blstutil.DSTSign)
		if sig == nil {
			writeError(conn, "BLS sign failed")
			return
		}
		resp.Result = sig.Compress()
	case enclaveproto.RequestSignPoP:
		sig := new(blst.P2Affine).Sign(sk, req.Message, blstutil.DSTPoP)
		if sig == nil {
			writeError(conn, "BLS SignPoP failed")
			return
		}
		resp.Result = sig.Compress()
	default:
		writeError(conn, fmt.Sprintf("unknown request type: %q", req.Type))
		return
	}

	_ = json.NewEncoder(conn).Encode(resp)
}

func writeError(conn net.Conn, msg string) {
	_ = json.NewEncoder(conn).Encode(enclaveproto.Response{Error: msg})
}

func zeroize(b []byte) {
	for i := range b {
		b[i] = 0
	}
}
