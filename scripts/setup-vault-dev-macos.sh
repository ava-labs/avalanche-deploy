#!/usr/bin/env bash
# Local Vault dev setup on macOS (smoke test only — E2E still needs Vault on the remote host).
#
#   cd /path/to/avalanche-kms-signer && bash scripts/setup-vault-dev-macos.sh
set -o errexit
set -o nounset
set -o pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_DIR="${HOME}/.vault/plugins"
MOUNT_PATH="${VAULT_MOUNT_PATH:-bls}"
export VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"

log() { printf '\n=== %s ===\n' "$*"; }

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Use scripts/setup-vault-host.sh on Linux (EC2)." >&2
  exit 1
fi

command -v vault >/dev/null || { echo "install vault: brew install hashicorp/tap/vault" >&2; exit 1; }

mkdir -p "$PLUGIN_DIR"

log "building plugin"
cd "${REPO}/vault-plugin"
CGO_ENABLED=1 go build -o "${PLUGIN_DIR}/vault-plugin-bls" .

if ! pgrep -f 'vault server' >/dev/null; then
  log "starting vault in dev mode"
  vault server -dev -dev-plugin-dir="$PLUGIN_DIR" -dev-listen-address=127.0.0.1:8200 \
    >/tmp/vault-dev.log 2>&1 &
  sleep 2
  ROOT_TOKEN="$(grep 'Root Token:' /tmp/vault-dev.log | awk '{print $NF}')"
  [[ -n "$ROOT_TOKEN" ]] || { echo "could not read root token from /tmp/vault-dev.log"; exit 1; }
  vault login "$ROOT_TOKEN"
fi

SHA="$(shasum -a 256 "${PLUGIN_DIR}/vault-plugin-bls" | awk '{print $1}')"
if ! vault plugin list -format=json 2>/dev/null | grep -q '"vault-plugin-bls"'; then
  vault plugin register -sha256="$SHA" secret vault-plugin-bls
fi

if ! vault secrets list -format=json 2>/dev/null | grep -q "\"${MOUNT_PATH}/\""; then
  vault secrets enable -path="$MOUNT_PATH" vault-plugin-bls
fi

vault write -force "${MOUNT_PATH}/keys/test/generate"
log "macOS dev vault ready at $VAULT_ADDR (see /tmp/vault-dev.log)"
