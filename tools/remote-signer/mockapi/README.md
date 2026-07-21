# mockapi/

> In-memory `api.Backend` for development and tests only — never for production.

## What this is
This package is the `memory` backend selected by `config.BackendMemory`. It implements the full `api.Backend` interface with a keypair held in process, so the gRPC server and integration tests can run with no cloud KMS, Vault, or enclave. It exists purely so you can exercise the signing path locally; it provides no key custody.

## Contents
- `memory.go` — the `Backend` type, `New` constructor, and the `PublicKey`/`Sign`/`SignProofOfPossession`/`Close` methods.
- `memory_test.go` — verifies key/signature sizes, DST separation, and that two instances differ.

## How it works
`New()` reads 32 random bytes, derives a scalar via `blstutil.KeyGen`, and caches the 48-byte public key with `blstutil.PublicKey`. `Sign` calls `blstutil.Sign(skBytes, msg, dstSign)` and `SignProofOfPossession` uses `dstPopProve`; both DSTs are aliases of `blstutil.DSTSign`/`blstutil.DSTPoP`, the same constants every other backend uses, so signatures are wire-compatible. `Close()` zeroes the in-memory scalar. Because the key is generated fresh on every `New()`, it changes on every process restart and is never written to disk.

## Troubleshooting
- "Validator's BLS key changed" / warp signatures stop verifying after restart: you are on the `memory` backend, which mints a new key each start. Switch `backend` to a real KMS/Vault/Nitro backend. The `serve` command also logs `using in-memory backend — DO NOT use in production`.
- Two nodes disagree on public key: each `mockapi.New()` produces an independent key (see `TestTwoInstancesHaveDifferentKeys`); the memory backend cannot share an identity across hosts.
- `Sign` and PoP return identical bytes: indicates DST separation is broken upstream in `blstutil` (the tests assert these differ).

## Related
- [../api/api.go](../api/api.go) — the `Backend` interface this implements.
- [../internal/blstutil/](../internal/blstutil/) — the actual BLS operations and DSTs.
- [../main/](../main/) — `buildBackend` wires `memory` to `mockapi.New`.
- Production backends and setup guides live in [../docs/](../docs/).
