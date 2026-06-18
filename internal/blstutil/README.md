# internal/blstutil/

> Pure-`[]byte` wrapper over the blst BLS12-381 bindings, and the single source of truth for AvalancheGo's domain-separation tags.

## What this is
This is the highest-stakes package in the repo: every signature the sidecar produces flows through `Sign` here, and the two DST constants it defines determine whether those signatures are accepted by the Avalanche network. It wraps `github.com/supranational/blst/bindings/go` so the rest of the codebase touches plain `[]byte` and never a cgo type. CGO is required to build it (blst compiles C sources directly).

## Contents
- `blstutil.go` — DST constants (`DSTSign`, `DSTPoP`), size constants, and `KeyGen` / `ValidateSecretKey` / `PublicKey` / `Sign`.

## How it works
AvalancheGo implements the IETF BLS **proof-of-possession ciphersuite**, so BOTH tags end in `RO_POP_`:
- `DSTSign` = `BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_` — warp / ICM message signatures.
- `DSTPoP` = `BLS_POP_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_` — proofs of possession (P2P handshake / validator registration).

`Sign(skBytes, msg, dst)` deserializes the 32-byte scalar, hashes `msg` to G2 under `dst`, and returns a 96-byte compressed signature. `PublicKey` returns the 48-byte compressed G1 key. `KeyGen` derives a scalar from ≥32 bytes of IKM; `ValidateSecretKey` checks a 32-byte scalar is non-zero and below the curve order. Callers pass `DSTSign` vs `DSTPoP` explicitly — `blstutil` never picks for you.

## Troubleshooting
- **Proofs of possession succeed but EVERY warp/ICM signature is silently rejected** → `Sign` was called with the basic-scheme `RO_NUL_` DST (or a hand-typed tag) instead of `DSTSign`. PoP uses a different tag so it keeps working, masking the bug. Fix: always pass `blstutil.DSTSign` for message signing. Never inline a DST string.
- `cgo: C compiler "..." not found` / blst build errors → CGO is disabled or no C toolchain. Build with `CGO_ENABLED=1` and a working C compiler.
- `invalid BLS key material — not a valid scalar` → bytes aren't a valid 32-byte scalar (wrong length, zero, or ≥ curve order); check the decrypted blob and key derivation.
- "IKM must be at least 32 bytes" → `KeyGen` input too short; supply ≥32 bytes of entropy.

## Related
- [`../enclaveproto/`](../enclaveproto/) — enclave requests map `RequestSign`→`DSTSign`, `RequestSignPoP`→`DSTPoP`.
- [`../../tests/`](../../tests/) — `compat_test.go` pins both DSTs to AvalancheGo and round-trips real signatures through `bls.Verify`.
- [`../../docs/architecture.md`](../../docs/architecture.md) — see the "Domain separation tags" section.
