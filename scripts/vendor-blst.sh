#!/usr/bin/env bash
# scripts/vendor-blst.sh
#
# go mod vendor only copies Go files.  blst requires its C headers and sources
# to be present alongside the Go bindings for CGO compilation.
#
# Run this script after every `go mod vendor` invocation:
#
#   go mod vendor && ./scripts/vendor-blst.sh
#
# The blst C sources are downloaded from the module cache the first time
# (requires `go mod download github.com/supranational/blst@v0.3.14`).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Read the blst version from go.mod
BLST_VERSION=$(grep 'supranational/blst' "$REPO_ROOT/go.mod" | grep -v indirect | awk '{print $2}')
if [[ -z "$BLST_VERSION" ]]; then
    echo "error: could not find supranational/blst version in go.mod" >&2
    exit 1
fi

BLST_CACHE="${GOPATH:-$HOME/go}/pkg/mod/github.com/supranational/blst@${BLST_VERSION}"
BLST_VENDOR="$REPO_ROOT/vendor/github.com/supranational/blst"

if [[ ! -d "$BLST_CACHE" ]]; then
    echo "blst not in module cache — downloading..."
    (cd "$REPO_ROOT" && go mod download "github.com/supranational/blst@${BLST_VERSION}")
fi

echo "Copying blst C sources from module cache (${BLST_VERSION})..."
cp -r "$BLST_CACHE/bindings" "$BLST_VENDOR/"
cp -r "$BLST_CACHE/src"      "$BLST_VENDOR/"
cp -r "$BLST_CACHE/build"    "$BLST_VENDOR/"
chmod -R u+w "$BLST_VENDOR/"

echo "Done. blst C sources vendored at: $BLST_VENDOR"
