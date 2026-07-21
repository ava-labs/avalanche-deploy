#!/usr/bin/env bash
# E2E test for the azure-kv backend on a reused Linux VM with Azure credentials.
#
# The VM should use a managed identity (or az login) with decrypt permission on
# the Key Vault RSA key.
#
# Usage:
#   E2E_HOST=1.2.3.4 E2E_SSH_KEY=~/.ssh/key.pem \
#   AZURE_VAULT_URL=https://my-vault.vault.azure.net AZURE_KEY_NAME=bls-signer \
#     ./scripts/e2e-azure.sh
set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=e2e/common.sh
source "$SCRIPT_DIR/e2e/common.sh"

: "${AZURE_VAULT_URL:?AZURE_VAULT_URL required}"
: "${AZURE_KEY_NAME:?AZURE_KEY_NAME required}"

e2e_run_reuse_host azure-kv \
  "AZURE_VAULT_URL=$AZURE_VAULT_URL AZURE_KEY_NAME=$AZURE_KEY_NAME"
