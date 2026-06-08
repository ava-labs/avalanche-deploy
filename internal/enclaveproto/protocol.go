// Copyright (C) 2024, Ava Labs, Inc. All rights reserved.
// See the file LICENSE for licensing terms.

// Package enclave defines the vsock protocol between the Nitro Enclave and
// the host signer process.
//
// The enclave listens on vsock port 5000.  The host sends a Request and
// receives a Response encoded as length-prefixed JSON.
//
// Message flow:
//
//	host                        enclave
//	 |  -- SignRequest -------->  |   decrypt key via KMS + sign
//	 |  <-- SignResponse -------  |   return signature
package enclaveproto

// RequestType identifies the operation the host is requesting.
type RequestType string

const (
	// RequestSign requests a BLS signature using the Warp DST.
	RequestSign RequestType = "sign"

	// RequestSignPoP requests a BLS signature using the proof-of-possession DST.
	RequestSignPoP RequestType = "sign_pop"

	// RequestPublicKey requests the compressed BLS public key.
	RequestPublicKey RequestType = "public_key"
)

// Request is sent from the host to the enclave over vsock.
type Request struct {
	Type    RequestType `json:"type"`
	Message []byte      `json:"message,omitempty"` // hex-encoded message to sign
}

// Response is sent from the enclave to the host.
type Response struct {
	// Result holds the signature (96 bytes) or public key (48 bytes),
	// hex-encoded.
	Result []byte `json:"result,omitempty"`

	// Error is non-empty if the operation failed.
	Error string `json:"error,omitempty"`
}

// InitMessage is sent from the host to the enclave on a separate port (5001)
// before signing requests begin.  It carries temporary AWS credentials so the
// enclave can call KMS without needing IMDS access (which is unavailable inside
// the enclave network).
//
// Security note: credentials cross the vsock boundary but the BLS plaintext key
// never does — this is still a significant improvement over Phase 1 where the
// key is decrypted on the host.  Full NSM attestation (where credentials are
// not needed) is a future enhancement.
type InitMessage struct {
	AccessKeyID     string `json:"access_key_id"`
	SecretAccessKey string `json:"secret_access_key"`
	SessionToken    string `json:"session_token"`
	Region          string `json:"region"`
}

// InitResponse is the enclave's reply to an InitMessage.
type InitResponse struct {
	PublicKey string `json:"public_key,omitempty"` // hex-encoded 48-byte G1 public key
	Error     string `json:"error,omitempty"`
}

// VSockPort is the port the enclave listens on for sign/public-key requests.
const VSockPort = 5000

// VSockInitPort is the port the enclave listens on for the one-time init message.
const VSockInitPort = 5001

// MaxMessageSize is the maximum allowed request/response size (1 MB).
const MaxMessageSize = 1 << 20
