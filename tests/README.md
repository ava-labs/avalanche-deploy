# tests/

> Cross-checks this signer's BLS output against AvalancheGo's own `bls` package, plus a live gRPC E2E validator.

## What this is

A separate Go module (`github.com/ava-labs/avalanche-remote-signer/tests`, own
`go.mod` with `replace ... => ../`, Go 1.25.8). It isolates the heavy
`github.com/ava-labs/avalanchego` dependency from the root module and shipped
binaries.

Two test surfaces:

1. **`compat_test.go`** — unit-style BLS DST and signature cross-checks (no network).
2. **`e2e/`** — live gRPC validator against a running signer (and optionally a node's pubkey/PoP).

## Contents

| Path | Purpose |
|---|---|
| `compat_test.go` | Asserts DSTs match avalanchego; round-trips signatures through `bls.Verify` / `bls.VerifyProofOfPossession`. |
| `e2e/main.go` | Drives a live signer over gRPC; used locally and by `scripts/e2e/remote-setup.sh` on EC2. |
| `go.mod` / `go.sum` | Module definition; pins `avalanchego` and replaces the root module with `../`. |

## `compat_test.go`

Regression guard for the `RO_NUL_` vs `RO_POP_` DST bug: proofs of possession can
work while every warp/ICM signature is silently rejected.

```bash
cd tests
CGO_ENABLED=1 go test ./...
```

## `e2e/` validator

With the signer running (e.g. `./avalanche-remote-signer serve`):

```bash
cd tests

# pubkey only
go run ./e2e --signer 127.0.0.1:50051 --pubkey-hex-only

# full sign + verify (no avalanchego node required)
go run ./e2e --signer 127.0.0.1:50051

# full stack on EC2 (node identity from info.getNodeID)
go run ./e2e --signer 127.0.0.1:50051 --node-pubkey 0x... --node-pop 0x...
```

## Troubleshooting

- **DST mismatch** → fix `internal/blstutil` DST constants; re-run `go test ./...`.
- **`Sign output does NOT verify`** → message-signing path regressed; same fix as above.
- **CGO / linker errors** → `CGO_ENABLED=1` and a C toolchain required.
- **`connection refused` on e2e** → start the signer first (`serve` listening on `127.0.0.1:50051`).

## Related

- [`../internal/blstutil/`](../internal/blstutil/) — signing core and DST constants.
- [`../docs/e2e.md`](../docs/e2e.md) — full AWS infrastructure E2E harness.
- [`../scripts/e2e-aws.sh`](../scripts/e2e-aws.sh) — orchestrator that runs `e2e` on EC2.
