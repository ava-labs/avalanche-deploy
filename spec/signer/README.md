# spec/signer/

> The source `signer.proto` that defines the gRPC signing contract; the single file you edit by hand.

## What this is
This folder contains `signer.proto`, a verbatim copy of avalanchego's [`proto/signer/signer.proto`](https://github.com/ava-labs/avalanchego/blob/master/proto/signer/signer.proto). It is the source of truth for the wire format between AvalancheGo and any BLS signing backend. The generated Go bindings in `../pb/signer/` are derived from this file; this file is never auto-generated and is the only proto you edit.

## Contents
- `signer.proto` — proto3 definition of the `Signer` service and its four message pairs

## How it works
`signer.proto` declares `package signer` and three unary RPCs on the `Signer` service:
- `PublicKey(PublicKeyRequest) -> PublicKeyResponse` — returns the compressed BLS public key bytes.
- `Sign(SignRequest) -> SignResponse` — signs `message` bytes (warp/ICM) with the message-signing DST `BLS_SIG_...RO_POP_`. Avalanche uses the IETF proof-of-possession *scheme*, so even the message DST ends in `RO_POP_` — it is **not** the basic-scheme `RO_NUL_` DST (that mistake passes registration and silently breaks every warp signature; see `internal/blstutil`).
- `SignProofOfPossession(SignProofOfPossessionRequest) -> SignProofOfPossessionResponse` — signs with the PoP DST `BLS_POP_...RO_POP_` used for validator proof-of-possession.

All payload fields are `bytes` (`public_key`, `message`, `signature`). The `option go_package` line pins the generated import path to `github.com/ava-labs/avalanche-remote-signer/spec/pb/signer`. To keep this file matching upstream, re-copy it from avalanchego when the protocol changes, then regenerate.

## Troubleshooting
- Changed this file but Go behavior didn't change → bindings weren't regenerated → run `./scripts/gen-proto.sh` from the repo root and commit `../pb/signer/`.
- Generated code lands in the wrong package path → the `option go_package` was altered → it must read `github.com/ava-labs/avalanche-remote-signer/spec/pb/signer`.
- Sign vs SignProofOfPossession confusion (warp signatures rejected) → wrong RPC/scheme used → validator PoP requires `SignProofOfPossession` (PoP/RO_POP_ DST), not `Sign`.

## Related
- [`../pb/signer/`](../pb/signer/) — generated bindings produced from this file
- [`../../scripts/`](../../scripts/) — `gen-proto.sh` runs `protoc` against this proto
- [`../README.md`](../README.md) — spec overview
