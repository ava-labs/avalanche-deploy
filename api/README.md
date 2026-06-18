# api/

> Defines the `Backend` signing interface and houses one subpackage per KMS provider.

## What this is
This is the backend abstraction layer for the signer. AvalancheGo talks gRPC to `signerserver/`, which delegates every cryptographic operation to a `Backend` implementation selected at startup. The `Backend` interface lives here in `api.go`; each subdirectory is a concrete implementation backed by a different key-management system. Adding a provider means implementing this interface and wiring it into `buildBackend` in `main/main.go` — nothing else changes.

## Contents
- `api.go` — the `Backend` interface: `PublicKey`, `Sign`, `SignProofOfPossession`, `Close`.
- `awskms/` — AWS KMS envelope-encryption backend (key decrypted into host memory).
- `gcpkms/` — Google Cloud KMS envelope-encryption backend.
- `azurekv/` — Azure Key Vault RSA-wrap backend.
- `vault/` — HashiCorp Vault backend (key never leaves Vault; signs over HTTP).
- `awsnitro/` — AWS Nitro Enclave backend (key decrypted and used only inside the enclave).

## How it works
`Backend` is the single contract every provider satisfies. `PublicKey` returns the 48-byte compressed BLS public key; `Sign` signs a Warp/ICM message; `SignProofOfPossession` signs a peer-handshake proof; `Close` releases resources (zeroes key bytes, closes clients, stops goroutines). Implementations must be safe for concurrent use — AvalancheGo calls `Sign`/`SignProofOfPossession` from multiple goroutines. The crucial split: `Sign` and `SignProofOfPossession` use *different* domain separation tags (see `internal/blstutil`); every backend routes them to `blstutil.DSTSign` vs `blstutil.DSTPoP` respectively. The in-process `memory` backend (dev only) lives in `mockapi/`, not here.

## Troubleshooting
- "unknown backend" at startup → the `backend:` value (config/env/flag) does not match a case in `buildBackend`; valid values are `memory`, `aws-kms`, `gcp-kms`, `azure-kv`, `vault`, `aws-nitro`.
- Registration/handshake succeeds but every Warp signature is rejected → a backend wired `Sign` to the PoP DST (or vice versa). The two methods must map to `DSTSign` and `DSTPoP` distinctly.
- New backend not being called → confirm it is added to `buildBackend` in `main/main.go`; implementing the interface alone does not register it.
- Compile/link errors mentioning blst or `_cgo_` → CGO is required (blst is a C library); build with `CGO_ENABLED=1`.

## Related
- [`awskms/`](./awskms/), [`gcpkms/`](./gcpkms/), [`azurekv/`](./azurekv/), [`vault/`](./vault/), [`awsnitro/`](./awsnitro/)
- [`../internal/blstutil`](../internal/blstutil/) — BLS primitives and the two DST constants.
- [`../signerserver`](../signerserver/) — the gRPC server that calls this interface.
- [`docs/architecture.md`](../docs/architecture.md) — system overview and key lifecycle.
