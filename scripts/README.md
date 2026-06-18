# scripts/

> Developer tooling scripts for this repo.

## What this is
Holds maintenance scripts run by hand from the repo root, not at build or runtime. Currently the only script regenerates the gRPC/protobuf Go bindings from the canonical `.proto` definition so the committed code in `spec/pb/signer/` stays in sync with `spec/signer/signer.proto`.

## Contents
- `gen-proto.sh` — regenerate `spec/pb/signer/*.pb.go` from `spec/signer/signer.proto`.

## How it works
`gen-proto.sh` resolves the repo root from its own location, then invokes `protoc` with `--proto_path=spec/signer`, writing both the message bindings (`--go_out`) and the service stubs (`--go-grpc_out`) into `spec/pb/signer/` using `paths=source_relative`. It runs under `set -euo pipefail`, so a missing tool or a `.proto` error aborts immediately.

Prerequisites (install once):
- `protoc` — `brew install protobuf` (or `apt install -y protobuf-compiler`)
- `protoc-gen-go` — `go install google.golang.org/protobuf/cmd/protoc-gen-go@latest`
- `protoc-gen-go-grpc` — `go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest`

Run from the repo root: `./scripts/gen-proto.sh`. The generated files (`signer.pb.go`, `signer_grpc.pb.go`) are committed but **must not be hand-edited** — change `signer.proto` and re-run the script, or your edits are lost on the next generation.

## Troubleshooting
- `protoc-gen-go: program not found or is not executable` → the plugins aren't on `PATH`. Run the `go install` lines above and ensure `$(go env GOPATH)/bin` is on `PATH`.
- `protoc: command not found` → install the protobuf compiler (`brew`/`apt` above).
- Generated code won't compile after editing → you edited a `*.pb.go` file by hand; revert, edit `spec/signer/signer.proto`, and re-run.
- Diff appears in `spec/pb/signer/` after running with no `.proto` change → plugin/protoc version drift; align tool versions with the rest of the team before committing.

## Related
- [`../spec/signer/`](../spec/signer/) — source `signer.proto`.
- [`../spec/pb/signer/`](../spec/pb/signer/) — generated output (do not edit).
- [`../signerserver/`](../signerserver/) — implements the generated `Signer` gRPC service.
