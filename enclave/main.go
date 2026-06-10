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
	"strings"
	"log"
	"net"
	"net/http"
	"os"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/kms"
	"github.com/aws/aws-sdk-go-v2/service/kms/types"
	"github.com/mdlayher/vsock"
	blst "github.com/supranational/blst/bindings/go"

	enclaveproto "github.com/ava-labs/avalanche-remote-signer/internal/enclaveproto"
)

// Domain separation tags — must match AvalancheGo exactly.
var (
	dstSign     = []byte("BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_")
	dstPopProve = []byte("BLS_POP_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_")
)

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
	defer zeroize(skBytes)

	// Step 3: deserialize and validate the BLS key.
	sk := new(blst.SecretKey)
	if sk.Deserialize(skBytes) == nil {
		sendInitResponse(initConn, "", "invalid BLS scalar")
		log.Fatal("invalid BLS scalar from KMS decrypt")
	}
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
// It keeps accepting connections until it receives a valid InitMessage,
// so that a probe connection (empty) doesn't consume the accept slot.
func receiveInit() (enclaveproto.InitMessage, net.Conn, error) {
	ln, err := vsock.Listen(enclaveproto.VSockInitPort, nil)
	if err != nil {
		return enclaveproto.InitMessage{}, nil, fmt.Errorf("vsock listen port %d: %w", enclaveproto.VSockInitPort, err)
	}
	// Note: do NOT defer ln.Close() — caller needs the listener open.

	for {
		conn, err := ln.Accept()
		if err != nil {
			ln.Close()
			return enclaveproto.InitMessage{}, nil, fmt.Errorf("accept: %w", err)
		}

		var msg enclaveproto.InitMessage
		if err := json.NewDecoder(conn).Decode(&msg); err != nil {
			// Empty or invalid connection — close and wait for the real one.
			conn.Close()
			continue
		}

		// Got a valid message — close the listener and return.
		ln.Close()
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

	resp, err := client.Decrypt(context.Background(), &kms.DecryptInput{
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
			log.Printf("accept error: %v", err)
			continue
		}
		go handleConn(conn, sk, pkBytes)
	}
}

func handleConn(conn net.Conn, sk *blst.SecretKey, pkBytes []byte) {
	defer conn.Close()

	var req enclaveproto.Request
	if err := json.NewDecoder(conn).Decode(&req); err != nil {
		writeError(conn, fmt.Sprintf("decode: %v", err))
		return
	}

	var resp enclaveproto.Response
	switch req.Type {
	case enclaveproto.RequestPublicKey:
		resp.Result = pkBytes
	case enclaveproto.RequestSign:
		sig := new(blst.P2Affine).Sign(sk, req.Message, dstSign)
		if sig == nil {
			writeError(conn, "BLS sign failed")
			return
		}
		resp.Result = sig.Compress()
	case enclaveproto.RequestSignPoP:
		sig := new(blst.P2Affine).Sign(sk, req.Message, dstPopProve)
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
