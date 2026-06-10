# Architecture

## Overview

`avalanche-remote-signer` is a gRPC sidecar that runs alongside AvalancheGo on a validator node. AvalancheGo delegates all BLS signing operations to the sidecar via the `signer.proto` interface, while the sidecar handles key storage and cryptographic operations using a pluggable backend.

```
┌─────────────────────────────────┐
│          Validator Host          │
│                                  │
│  ┌───────────────┐               │
│  │  AvalancheGo  │               │
│  │               │──gRPC (50051)─┼──▶┌────────────────────────┐
│  │  peer handshakes              │   │ avalanche-remote-signer│
│  │  ICM messages  │◀─────────────┼───│                        │
│  └───────────────┘  signatures  │   │  PublicKey()           │
│                                  │   │  Sign()                │
│  ┌───────────────┐               │   │  SignProofOfPossession │
│  │ bls.key.enc   │               │   └──────────┬─────────────┘
│  │ (ciphertext)  │◀──────────────┼──────────────┘
│  └───────────────┘  read once    │         │ decrypt at startup
└─────────────────────────────────┘         │
                                             ▼
                                    ┌─────────────────┐
                                    │   Cloud KMS     │
                                    │   AWS / GCP /   │
                                    │   Azure         │
                                    └─────────────────┘
```

---

## Key lifecycle

```
SETUP (once, by operator)                RUNTIME (continuous)
─────────────────────────                ────────────────────
generate/migrate                         startup
     │                                      │
     ▼                                      ▼
BLS key (32 bytes)               bls.key.enc ──kms:Decrypt──▶ BLS key in memory
     │                                                              │
     ▼                                                              ▼
kms:Encrypt                                              AvalancheGo request
     │                                                              │
     ▼                                                              ▼
bls.key.enc (disk)                                       blst sign in-process
                                                                    │
                                                                    ▼
                                                          signature returned
                                                          over gRPC
                                          shutdown
                                              │
                                              ▼
                                         key zeroed from memory
```

The KMS API is called **once at startup** (to decrypt the key blob). All subsequent signing calls are local — signing latency is microseconds, not milliseconds, and the signer imposes no per-request cloud API overhead.

---

## Package structure

### `internal/blstutil`

A thin wrapper over [blst](https://github.com/supranational/blst) v0.3.14's official Go bindings. It exposes four pure-Go functions — `KeyGen`, `ValidateSecretKey`, `PublicKey`, `Sign` — that take and return `[]byte`. No CGO types are exposed to the rest of the codebase.

blst v0.3.14 fixed a CGO type alias incompatibility that affected earlier versions on Go 1.22+. The C headers and sources are vendored alongside the Go bindings in `vendor/github.com/supranational/blst/` since `go mod vendor` only copies Go files.

### `backend`

Defines the `Backend` interface:

```go
type Backend interface {
    PublicKey(ctx context.Context) ([]byte, error)
    Sign(ctx context.Context, msg []byte) ([]byte, error)
    SignProofOfPossession(ctx context.Context, msg []byte) ([]byte, error)
    Close() error
}
```

Each backend implementation (`memory`, `awskms`, `gcpkms`, `azurekv`) satisfies this interface. Adding a new cloud provider means implementing this interface and adding a case to `buildBackend` in `main.go` — nothing else changes.

### `signerserver`

Wraps a `Backend` in a gRPC server that implements the `signer.proto` `Signer` service. It is entirely backend-agnostic.

### `keytool`

Contains the `Generate` and `Migrate` functions used by the CLI. These functions:

1. Produce or read a 32-byte BLS scalar
2. Call the appropriate cloud KMS `Encrypt` API
3. Write the ciphertext blob to disk
4. Return the derived public key hex for the operator to verify

### `config`

Loads configuration from YAML files and environment variables. The config struct is the single source of truth for all backend settings — no backend package defines its own config.

### `main`

The cobra CLI with three subcommands: `serve`, `keytool generate`, `keytool migrate`.

---

## Domain separation tags

BLS signing requires a domain separation tag (DST) to bind signatures to their intended context. AvalancheGo implements the IETF BLS **proof-of-possession scheme**, so the message-signing DST carries the `POP_` scheme tag — it is *not* the basic-scheme `NUL_` DST:


| Method                  | DST                                           | Used for                          |
| ----------------------- | --------------------------------------------- | --------------------------------- |
| `Sign`                  | `BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_` | Warp / ICM message signatures     |
| `SignProofOfPossession` | `BLS_POP_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_` | P2P handshake proof-of-possession |


These constants live in one place — `internal/blstutil` (`DSTSign`, `DSTPoP`) — and every backend references them. Getting `Sign`'s DST wrong is an especially nasty failure mode: proofs of possession (and therefore validator registration) keep working while **every warp/ICM signature is silently rejected** by the network.

Signatures produced by this sidecar are **identical** to those AvalancheGo would produce with the same key — they verify with the same public key and the same verification logic. This is enforced, not assumed: the `compat/` test module pins both DSTs to AvalancheGo's ciphersuites and round-trips real signatures through avalanchego's `bls.Verify` / `bls.VerifyProofOfPossession` (`cd compat && go test ./...`).

---

## Blob format

The on-disk encrypted blob (`bls.key.enc`) is the **raw ciphertext** returned by the cloud KMS Encrypt API, applied to the 32-byte big-endian BLS scalar. There is no additional framing, versioning, or metadata.

This is intentionally minimal: the KMS key ID is stored in config, not in the blob, and the blob format is identical across all three cloud backends. Migrating between cloud providers means re-encrypting the scalar with a different KMS key — the blob format does not need to change.

---

## Security boundaries


| Boundary                | Detail                                                                             |
| ----------------------- | ---------------------------------------------------------------------------------- |
| Key material at rest    | 32-byte scalar is encrypted with the cloud KMS key; only ciphertext on disk        |
| Key material in transit | KMS API calls use TLS; gRPC binds to loopback by default                           |
| Key material in memory  | Held in a Go `[]byte`; zeroed in `Close()`                                         |
| Process isolation       | Signer runs as a separate process from AvalancheGo; can run as a dedicated OS user |
| KMS credential scope    | Production IAM roles need only `Decrypt`; `Encrypt` is only needed at setup time   |


### What this does NOT protect against

- **OS-level memory reads** (cloud KMS backends): a process with sufficient privilege (e.g. `ptrace`, `/proc/mem`) could read the key from the signer process. The [AWS Nitro Enclave backend](aws-nitro.md) closes this gap — the key is decrypted and used exclusively inside the enclave VM, and the host never holds plaintext.
- **Compromised KMS credentials**: if the IAM role / service account credentials are stolen, an attacker can decrypt the blob. Use short-lived credentials (instance profiles, workload identity) to limit exposure.
- **Side-channel attacks**: blst uses constant-time arithmetic, but the signer does not provide timing-attack mitigations at the process level.

---

## Testing approach

Each backend has two test types:

**Unit tests** (always run, no cloud credentials needed):

- Use an XOR mock that simulates encrypt/decrypt
- Test the full round-trip: key generation → mock encrypt → mock decrypt → sign → public key check
- Run with `CGO_ENABLED=1 go test ./backend/...`

**Integration tests** (skipped unless env vars are set):

- Talk to a real cloud KMS key
- Test that the signer can decrypt a blob produced by keytool and sign a message
- Triggered by setting `AWS_KMS_KEY_ID` / `GCP_PROJECT` / `AZURE_VAULT_URL` etc.

