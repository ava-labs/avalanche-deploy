#!/usr/bin/env bash
# scripts/gen-proto.sh
# Regenerate Go bindings from proto/signer/signer.proto.
#
# Prerequisites (install once):
#   go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
#   go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest
#   brew install protobuf   # or: apt install -y protobuf-compiler
#
# Run from the repo root:
#   ./scripts/gen-proto.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROTO_DIR="$REPO_ROOT/proto/signer"
OUT_DIR="$REPO_ROOT/proto/pb/signer"

mkdir -p "$OUT_DIR"

protoc \
  --proto_path="$PROTO_DIR" \
  --go_out="$OUT_DIR" \
  --go_opt=paths=source_relative \
  --go-grpc_out="$OUT_DIR" \
  --go-grpc_opt=paths=source_relative \
  "$PROTO_DIR/signer.proto"

echo "Generated pb files in $OUT_DIR"
