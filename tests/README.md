# tests/

> Cross-checks this signer's BLS output against AvalancheGo's own `bls` package so on-network signatures are guaranteed to verify.

## What this is
A separate Go module (`github.com/ava-labs/avalanche-remote-signer/tests`, own `go.mod` with `replace ... => ../`). It is isolated into its own module so the heavy `github.com/ava-labs/avalanchego` dependency stays out of the root module and the shipped binaries — it's pulled in only when running these compatibility tests. This module was formerly named `compat/`. It exists because a real bug shipped: `Sign()` used the IETF basic-scheme DST (`...RO_NUL_`) instead of AvalancheGo's proof-of-possession scheme DST (`...RO_POP_`), so proofs of possession (and validator registration) worked while every warp/ICM signature was silently rejected on-network.

## Contents
- `compat_test.go` — the cross-verification tests against `avalanchego/utils/crypto/bls`.
- `go.mod` / `go.sum` — module definition; requires `avalanchego` and replaces the root module with `../`.

## How it works
The tests exercise `internal/blstutil` (this signer's signing core) and verify with the real `avalanchego` `bls` package:
- `TestDSTsMatchAvalancheGo` — asserts `blstutil.DSTSign` equals `avabls.CiphersuiteSignature` and `blstutil.DSTPoP` equals `avabls.CiphersuiteProofOfPossession`, byte-for-byte. This is the direct regression guard for the `RO_NUL_` vs `RO_POP_` bug.
- `TestSignaturesVerifyUnderAvalancheGo` — generates a key with `blstutil.KeyGen`, then checks both directions:
  - a `DSTSign` signature verifies under `avabls.Verify` (warp/ICM) and is rejected by `avabls.VerifyProofOfPossession`;
  - a `DSTPoP` signature verifies under `avabls.VerifyProofOfPossession` (registration) and is rejected by `avabls.Verify`.
  The cross-negative assertions catch the case where the two DSTs are accidentally swapped.

## Build & run
This is a separate module, so `cd` in first; CGO is required because `blstutil` links `blst`.
```sh
cd tests
CGO_ENABLED=1 go test ./...
# verbose:
CGO_ENABLED=1 go test -v ./...
```

## Troubleshooting
- **`DSTSign = ... avalanchego CiphersuiteSignature = ...` mismatch** → someone changed a DST constant in `internal/blstutil` (e.g. back to `...RO_NUL_`). → Restore the `...RO_POP_` ciphersuite values; never edit DSTs without re-running this test.
- **`Sign output does NOT verify as an avalanchego message signature`** → the message-signing path regressed (wrong DST or wrong hash-to-curve). → Fix `blstutil.Sign`; this is the exact "PoP works but warp signatures rejected" failure.
- **`undefined: blst...` / linker errors** → built with `CGO_ENABLED=0`. → Re-run with `CGO_ENABLED=1` and a working C toolchain.
- **`avalanchego` version drift after `go get -u`** → ciphersuite strings could change upstream. → Keep the `avalanchego` version pinned in `go.mod` and bump deliberately.

## Related
- [`../internal/blstutil/`](../internal/blstutil/) — the signing core and DST constants under test.
- [`../docs/architecture.md`](../docs/architecture.md) — package structure and key lifecycle.
- [`../enclave/`](../enclave/) — duplicates the same DSTs inline; keep in sync with `blstutil`.
