// Copyright (C) 2024, Ava Labs, Inc. All rights reserved.
// See the file LICENSE for licensing terms.

// enclave/main.go runs inside the AWS Nitro Enclave.  It:
//
//  1. Reads the encrypted BLS key blob from a file path passed as the first
//     argument (the blob is baked into the enclave image at build time).
//  2. Calls AWS KMS Decrypt via the KMS proxy running on the host.
//     The proxy runs on vsock CID 3 and forwards requests to real AWS KMS
//     while attaching the enclave attestation document automatically.
//     KMS only decrypts when the PCRs in the attestation match the key policy.
//  3. Holds the plaintext BLS key in memory.
//  4. Listens on vsock port 5000 for sign/public-key requests from the host.

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"os"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/kms"
	"github.com/aws/aws-sdk-go-v2/service/kms/types"
	blst "github.com/supranational/blst/bindings/go"
	"github.com/mdlayher/vsock"

	enclaveproto "github.com/ava-labs/avalanche-kms-signer/internal/enclaveproto"
)

// Domain separation tags — must match AvalancheGo exactly.
var (
	dstSign     = []byte("BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_NUL_")
	dstPopProve = []byte("BLS_POP_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_")
)

// hostVSockCID is the vsock CID of the host — always 3 inside an enclave.
const hostVSockCID = 3

// kmsProxyPort is the port the nitro-kms-proxy listens on on the host.
const kmsProxyPort = 8443

func main() {
	if len(os.Args) < 3 {
		log.Fatal("usage: enclave <encrypted-key-path> <kms-key-id>")
	}
	encryptedKeyPath := os.Args[1]
	kmsKeyID := os.Args[2]

	// Read the encrypted BLS key blob baked into the image.
	ciphertext, err := os.ReadFile(encryptedKeyPath)
	if err != nil {
		log.Fatalf("reading encrypted key: %v", err)
	}

	// Decrypt via KMS proxy on the host (vsock CID 3).
	// The proxy attaches the enclave attestation document to the request,
	// so KMS only decrypts if the PCRs match the key policy.
	skBytes, err := decryptWithKMSProxy(kmsKeyID, ciphertext)
	if err != nil {
		log.Fatalf("KMS decrypt: %v", err)
	}
	defer zeroize(skBytes)

	// Deserialize the BLS key.
	sk := new(blst.SecretKey)
	if sk.Deserialize(skBytes) == nil {
		log.Fatal("invalid BLS scalar from KMS decrypt")
	}
	pk := new(blst.P1Affine).From(sk)
	pkBytes := pk.Compress()

	log.Printf("enclave ready, public key length: %d bytes", len(pkBytes))

	// Serve signing requests over vsock.
	if err := serve(sk, pkBytes); err != nil {
		log.Fatalf("vsock server: %v", err)
	}
}

// decryptWithKMSProxy calls the KMS proxy on the host over vsock.
// The proxy (github.com/aws/aws-nitro-enclaves-sdk-go or nitro-kms-proxy)
// forwards the request to AWS KMS and injects the attestation document.
func decryptWithKMSProxy(keyID string, ciphertext []byte) ([]byte, error) {
	// Point the KMS client at the vsock proxy.
	// The proxy listens on CID 3 (host) and proxies to real AWS KMS.
	proxyEndpoint := fmt.Sprintf("http://vsock:%d:%d", hostVSockCID, kmsProxyPort)

	cfg, err := config.LoadDefaultConfig(context.Background())
	if err != nil {
		return nil, fmt.Errorf("loading AWS config: %w", err)
	}

	client := kms.NewFromConfig(cfg, func(o *kms.Options) {
		o.BaseEndpoint = aws.String(proxyEndpoint)
	})

	resp, err := client.Decrypt(context.Background(), &kms.DecryptInput{
		KeyId:               aws.String(keyID),
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

// serve listens on vsock port 5000 for requests from the host.
func serve(sk *blst.SecretKey, pkBytes []byte) error {
	ln, err := vsock.Listen(enclaveproto.VSockPort, nil)
	if err != nil {
		return fmt.Errorf("vsock listen on port %d: %w", enclaveproto.VSockPort, err)
	}
	log.Printf("listening on vsock port %d", enclaveproto.VSockPort)

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

	if err := json.NewEncoder(conn).Encode(resp); err != nil {
		log.Printf("encode response: %v", err)
	}
}

func writeError(conn net.Conn, msg string) {
	_ = json.NewEncoder(conn).Encode(enclaveproto.Response{Error: msg})
}

func zeroize(b []byte) {
	for i := range b {
		b[i] = 0
	}
}
