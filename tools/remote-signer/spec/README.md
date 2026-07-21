# spec/

> The gRPC contract between AvalancheGo and this remote signer: the source `.proto` plus its generated Go bindings.

## What this is
`spec/` holds the wire protocol AvalancheGo uses to talk to a BLS signing sidecar. `signer/signer.proto` is the hand-maintained source of truth (a copy of avalanchego's `signer.proto`); `pb/signer/` holds the Go bindings generated from it by `protoc`. Unlike the rest of the repo, nothing here needs CGO — it is pure protocol, no blst. The folder is named `spec/` (not `proto/`) so the `go_package` path mirrors the cube-signer-sidecar reference layout.

## Contents
- `signer/signer.proto` — source proto defining the `Signer` service (`PublicKey`, `Sign`, `SignProofOfPossession`)
- `pb/signer/signer.pb.go` — generated message types (do not edit)
- `pb/signer/signer_grpc.pb.go` — generated gRPC client/server stubs (do not edit)

## How it works
The `.proto` declares the service and its request/response messages. Running `scripts/gen-proto.sh` invokes `protoc` with `paths=source_relative`, reading `spec/signer/signer.proto` and writing both `.pb.go` files into `spec/pb/signer/`. The `option go_package` in the proto fixes the import path to `github.com/ava-labs/avalanche-deploy/tools/remote-signer/spec/pb/signer`, which `signerserver/` imports as `pb`. The proto and the bindings must always stay in sync: edit the proto, then regenerate — never the reverse.

## Troubleshooting
- Build/runtime mismatch (unknown field, wrong message shape) → bindings out of sync with the proto → re-run `./scripts/gen-proto.sh` and commit both folders together.
- Hand-edited a `.pb.go` and it later reverted → generated files are overwritten on regen → make the change in `signer/signer.proto` instead, then regenerate.
- Import path won't resolve → the `go_package` option or module path drifted → confirm `option go_package` matches `module` in `go.mod` (`github.com/ava-labs/avalanche-deploy/tools/remote-signer`).

## Related
- [`signer/`](./signer/) — the `.proto` source
- [`pb/signer/`](./pb/signer/) — the generated bindings
- [`../scripts/`](../scripts/) — `gen-proto.sh` regenerates the bindings
- [`../signerserver/`](../signerserver/) — implements the service from these bindings
