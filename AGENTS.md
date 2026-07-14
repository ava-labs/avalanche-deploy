# AGENTS.md

Orientation for this repository — a folder-by-folder map so a human (or agent) can
navigate and troubleshoot **without reading the source**. Every directory also has
its own `README.md` with detail; this file is the index and the mental model.

## What this repo is

`avalanche-remote-signer` is a self-hosted **BLS signing sidecar** for
[AvalancheGo](https://github.com/ava-labs/avalanchego) validators. AvalancheGo uses
BLS12-381 keys for peer handshakes (proof of possession) and to sign ICM / warp
messages. This sidecar keeps the private key in a cloud KMS (AWS / GCP / Azure),
HashiCorp Vault, or an AWS Nitro enclave, and answers signing requests over gRPC —
so the validator process never holds the key in memory or on disk.

AvalancheGo connects to it with `--staking-rpc-signer-endpoint=127.0.0.1:50051`.

It is the open-source counterpart to the proprietary
[cube-signer-sidecar](https://github.com/ava-labs/cube-signer-sidecar) (whose layout
this repo mirrors).

## Request flow

```
AvalancheGo ──gRPC──▶ signerserver ──▶ api.Backend ──▶ cloud KMS / Vault / enclave
                      (spec/signer)     (one provider)    (decrypt key, BLS sign)
```

Everything funnels through the `api.Backend` interface
(`PublicKey`, `Sign`, `SignProofOfPossession`, `Close`) defined in `api/api.go`.
Adding a provider = implement that interface + register it in `main/`.

## The four Go modules

| Module | Path | Why separate |
|---|---|---|
| **root** | `.` | the server, CLI, and all KMS backends |
| **enclave** | `enclave/` | builds a statically-linked binary that runs *inside* a Nitro enclave |
| **vault-plugin** | `vault-plugin/` | a standalone HashiCorp Vault secrets-plugin binary |
| **tests** | `tests/` | isolates the heavy `avalanchego` dependency; BLS compat tests + live `e2e` validator |

`enclave/` and `tests/` use `replace => ../` to build against the root module.
All modules target **Go 1.25.12** (root `go.mod`, `tests/go.mod`, `enclave/`, `vault-plugin/`).

## Folder map

| Folder | What it is |
|---|---|
| `main/` | Entry point + cobra CLI (`serve`, `keytool`) |
| `signerserver/` | gRPC server implementing the signer service; delegates to an `api.Backend` |
| `api/` | The `Backend` interface and all KMS provider implementations |
| `api/awskms/` | AWS KMS backend |
| `api/gcpkms/` | GCP Cloud KMS backend (🧪 experimental — not yet E2E-validated) |
| `api/azurekv/` | Azure Key Vault backend (🧪 experimental — not yet E2E-validated) |
| `api/vault/` | HashiCorp Vault backend (talks to `vault-plugin/`) |
| `api/awsnitro/` | AWS Nitro enclave backend (host side; talks to `enclave/` over vsock) |
| `mockapi/` | In-memory backend — **dev/test only**, never production |
| `spec/signer/` | `signer.proto` — the gRPC service definition |
| `spec/pb/signer/` | Generated Go bindings — **do not edit**, regenerate via `scripts/gen-proto.sh` |
| `config/` | Config struct, YAML loading, env/flag overrides |
| `keytool/` | Generate or migrate an encrypted BLS key blob |
| `internal/blstutil/` | blst (BLS12-381) wrapper + the canonical **DSTs** — the highest-stakes file |
| `internal/enclaveproto/` | Host ↔ enclave wire protocol (vsock JSON) |
| `enclave/` | Code that runs INSIDE the Nitro enclave (separate module) |
| `vault-plugin/` | Custom Vault secrets plugin (separate binary) |
| `tests/` | BLS compat tests (`compat_test.go`) + live gRPC validator (`e2e/`) |
| `scripts/` | `gen-proto.sh`, `e2e-aws.sh`, `e2e-gcp.sh`, `e2e-azure.sh`, `e2e-vault.sh`, `e2e-aws-nitro.sh`, `e2e/` shared helpers |
| `docs/` | Setup guides (AWS KMS, GCP, Azure, Vault, Nitro), architecture, [e2e.md](docs/e2e.md) |

## Build & test

```bash
export CGO_ENABLED=1               # REQUIRED everywhere — blst uses cgo
go build ./...                     # root module
go test ./...                      # root unit tests (integration tests skip without creds)
( cd tests && go test ./... )      # BLS DST cross-check vs avalanchego
( cd enclave && go build ./... )   # separate module
( cd vault-plugin && go build ./... )

# live signer smoke test (signer must be running in another terminal)
( cd tests && go run ./e2e --signer 127.0.0.1:50051 )

# AWS integration test (example — needs real KMS key + encrypted blob)
AWS_KMS_KEY_ID=arn:... AWS_REGION=... AWS_ENCRYPTED_BLS_KEY_PATH=/abs/path/bls.key.enc \
  go test ./api/awskms/ -run TestIntegration

# full AWS E2E (EC2 + KMS + AvalancheGo — costs money)
./scripts/e2e-aws.sh
# GCP / Azure / Vault / Nitro — reuse an existing VM (see docs/e2e.md)
E2E_HOST=... E2E_SSH_KEY=... ./scripts/e2e-gcp.sh
```

See [README.md](README.md#documentation) for the documentation index and
[docs/e2e.md](docs/e2e.md) for reuse mode when org SCPs block resource creation.

## Troubleshooting — where to start

| Symptom | Most likely cause / where to look |
|---|---|
| Registration & PoP work, but **every warp/ICM signature is rejected** by the network | BLS **DST mismatch** — `Sign` must use the proof-of-possession ciphersuite (`…RO_POP_`), not the basic one (`…RO_NUL_`). See `internal/blstutil/`; verify with `tests/`. |
| `undefined: ...` / cgo errors at build | `CGO_ENABLED=1` not set, or no C compiler. blst needs cgo. |
| Enclave dies silently; host times out dialing vsock | enclave binary not **statically linked** (Alpine/musl), or wrong vsock CID/port. See `enclave/` + `api/awsnitro/`. |
| `decrypt`/permission errors at startup | KMS credentials/IAM scope (needs `Decrypt`) or wrong key ID/region/vault path. See the relevant `api/<provider>/` + `docs/`. |
| gRPC client can't connect | Wrong listen address/port; signer binds loopback by default. See `config/` + `signerserver/`. |
| Generated proto out of sync after editing `.proto` | Run `scripts/gen-proto.sh`. Never hand-edit `spec/pb/signer/`. |

## Conventions

- **CGO is mandatory** — every build/test command needs `CGO_ENABLED=1`.
- A new signing backend = implement `api.Backend` and register it in `main/`. No other code changes needed.
- `spec/pb/signer/` is generated from `spec/signer/signer.proto`; edit the `.proto` and regenerate.
- The encrypted key blob (`bls.key.enc`) is raw KMS ciphertext over the 32-byte BLS scalar — identical format across all cloud backends.
