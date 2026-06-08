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

// VSockPort is the port the enclave listens on.
const VSockPort = 5000

// MaxMessageSize is the maximum allowed request/response size (1 MB).
const MaxMessageSize = 1 << 20
