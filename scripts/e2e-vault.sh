#!/usr/bin/env bash
# E2E test for the vault backend on a reused Linux host running Vault + the BLS plugin.
#
# Prerequisites on the host: Vault server, vault-plugin-bls registered at mount_path.
# See docs/vault.md.
#
# Usage:
#   E2E_HOST=1.2.3.4 E2E_SSH_KEY=~/.ssh/key.pem \
#   VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=... VAULT_KEY_NAME=validator \
#     ./scripts/e2e-vault.sh
set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=e2e/common.sh
source "$SCRIPT_DIR/e2e/common.sh"

: "${VAULT_ADDR:?VAULT_ADDR required}"
: "${VAULT_TOKEN:?VAULT_TOKEN required}"
: "${VAULT_KEY_NAME:?VAULT_KEY_NAME required}"
VAULT_MOUNT_PATH="${VAULT_MOUNT_PATH:-bls}"

e2e_run_reuse_host vault \
  "VAULT_ADDR=$VAULT_ADDR VAULT_TOKEN=$VAULT_TOKEN VAULT_MOUNT_PATH=$VAULT_MOUNT_PATH VAULT_KEY_NAME=$VAULT_KEY_NAME"
