#!/usr/bin/env bash
# E2E test for the gcp-kms backend on a reused Linux VM with GCP credentials.
#
# The VM must have Application Default Credentials or a attached service account
# with roles/cloudkms.cryptoKeyEncrypterDecrypter on the target key.
#
# Usage:
#   E2E_HOST=1.2.3.4 E2E_SSH_KEY=~/.ssh/key.pem \
#   GCP_PROJECT=my-project GCP_LOCATION=us-central1 \
#   GCP_KEY_RING=avalanche GCP_KEY_NAME=bls-signer \
#     ./scripts/e2e-gcp.sh
set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=e2e/common.sh
source "$SCRIPT_DIR/e2e/common.sh"

: "${GCP_PROJECT:?GCP_PROJECT required}"
: "${GCP_LOCATION:?GCP_LOCATION required}"
: "${GCP_KEY_RING:?GCP_KEY_RING required}"
: "${GCP_KEY_NAME:?GCP_KEY_NAME required}"

e2e_run_reuse_host gcp-kms \
  "GCP_PROJECT=$GCP_PROJECT GCP_LOCATION=$GCP_LOCATION GCP_KEY_RING=$GCP_KEY_RING GCP_KEY_NAME=$GCP_KEY_NAME"
