# internal/

> Go `internal/` packages: shared building blocks usable only inside this module.

## What this is
Everything under `internal/` is importable only by packages rooted at `github.com/ava-labs/avalanche-remote-signer` — Go's compiler enforces this, so these packages are private implementation detail, not a public API. They hold the cross-cutting primitives the signer, keytool, backends, and enclave all depend on: BLS cryptography and the host↔enclave wire protocol.

## Contents
- `blstutil/` — pure-Go wrapper over the blst BLS12-381 bindings; owns the canonical AvalancheGo DSTs.
- `enclaveproto/` — vsock request/response types exchanged between the host process and an AWS Nitro Enclave.

## How it works
`blstutil` exposes `KeyGen`, `ValidateSecretKey`, `PublicKey`, and `Sign` taking/returning `[]byte`, plus the `DSTSign`/`DSTPoP` domain-separation tags — every backend that signs goes through it. `enclaveproto` defines the `Request`/`Response`/`InitMessage` JSON types and vsock port constants shared by `api/awsnitro` (host side) and `enclave/` (enclave side). Neither package imports the other; both are leaf dependencies.

## Troubleshooting
- "use of internal package not allowed" → the importer lives outside this module. `internal/` is only reachable from within `github.com/ava-labs/avalanche-remote-signer`; copy the code or move it out of `internal/` if it must be shared externally.
- A new subpackage isn't picked up → confirm its import path is under the module root; an unintended replace directive or vendored copy can shadow it.

## Related
- [`blstutil/`](blstutil/) — BLS signing primitives and DSTs.
- [`enclaveproto/`](enclaveproto/) — host/enclave wire protocol.
- [`../docs/architecture.md`](../docs/architecture.md) — package structure and where these fit.
