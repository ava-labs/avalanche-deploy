#!/usr/bin/env bash
# scripts/e2e/remote-setup.sh
#
# Runs ON a remote Linux host (SSH). Builds the signer, provisions a key for the
# selected backend, starts the signer + avalanchego, and runs tests/e2e.
#
# Required env:
#   E2E_BACKEND — aws-kms | gcp-kms | azure-kv | vault
#
# Backend-specific (see docs/e2e.md):
#   aws-kms:   AWS_REGION, KMS_KEY_ARN (or E2E_KMS_KEY_ARN)
#   gcp-kms:   GCP_PROJECT, GCP_LOCATION, GCP_KEY_RING, GCP_KEY_NAME
#   azure-kv:  AZURE_VAULT_URL, AZURE_KEY_NAME
#   vault:     VAULT_ADDR, VAULT_TOKEN, VAULT_KEY_NAME; optional VAULT_MOUNT_PATH
set -o errexit
set -o nounset
set -o pipefail

E2E_BACKEND="${E2E_BACKEND:-aws-kms}"
REPO="${REPO:-$HOME/remote-signer}"
SIGNER_ADDR="127.0.0.1:50051"
SIGNER_BIN="/tmp/avalanche-remote-signer"
BLOB_PATH="/tmp/bls.key.enc"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

umask 077 # the signer config may hold a Vault token — keep created files owner-only

# Restore production services and clean up test processes on ANY exit, so a
# failure (or success) never leaves the validator down or ports held.
cleanup() {
  set +e
  [[ -n "${SIGNER_PID:-}" ]] && kill "$SIGNER_PID" 2>/dev/null
  kill_listeners_on_port 50051
  kill_listeners_on_port 9650
  rm -f /tmp/signer.yaml
  restart_prod_services
}
# NOTE: the trap is armed later, right before we first stop/kill anything — an
# early exit (e.g. bad backend, keytool failure) must not kill prod listeners.

case "$E2E_BACKEND" in
  aws-kms)
    AWS_REGION="${AWS_REGION:?AWS_REGION required}"
    KMS_KEY_ARN="${KMS_KEY_ARN:-${E2E_KMS_KEY_ARN:?KMS_KEY_ARN or E2E_KMS_KEY_ARN required}}"
    ;;
  gcp-kms)
    GCP_PROJECT="${GCP_PROJECT:?GCP_PROJECT required}"
    GCP_LOCATION="${GCP_LOCATION:?GCP_LOCATION required}"
    GCP_KEY_RING="${GCP_KEY_RING:?GCP_KEY_RING required}"
    GCP_KEY_NAME="${GCP_KEY_NAME:?GCP_KEY_NAME required}"
    ;;
  azure-kv)
    AZURE_VAULT_URL="${AZURE_VAULT_URL:?AZURE_VAULT_URL required}"
    AZURE_KEY_NAME="${AZURE_KEY_NAME:?AZURE_KEY_NAME required}"
    ;;
  vault)
    VAULT_ADDR="${VAULT_ADDR:?VAULT_ADDR required}"
    VAULT_TOKEN="${VAULT_TOKEN:?VAULT_TOKEN required}"
    VAULT_KEY_NAME="${VAULT_KEY_NAME:?VAULT_KEY_NAME required}"
    VAULT_MOUNT_PATH="${VAULT_MOUNT_PATH:-bls}"
    ;;
  *)
    echo "unsupported E2E_BACKEND=$E2E_BACKEND (use aws-kms, gcp-kms, azure-kv, or vault; aws-nitro uses remote-setup-nitro.sh)" >&2
    exit 1
    ;;
esac

e2e_setup_log "installing dependencies"
install_build_deps
install_go

e2e_setup_log "building the signer"
cd "$REPO"
go build -o "$SIGNER_BIN" ./main/

e2e_setup_log "generating BLS key (keytool generate, ${E2E_BACKEND})"
KEYTOOL_ARGS=(keytool generate --backend "$E2E_BACKEND")
case "$E2E_BACKEND" in
  aws-kms)
    KEYTOOL_ARGS+=(--aws-region "$AWS_REGION" --aws-kms-key-id "$KMS_KEY_ARN" --output "$BLOB_PATH")
    ;;
  gcp-kms)
    KEYTOOL_ARGS+=(--gcp-project "$GCP_PROJECT" --gcp-location "$GCP_LOCATION" \
      --gcp-key-ring "$GCP_KEY_RING" --gcp-key-name "$GCP_KEY_NAME" --output "$BLOB_PATH")
    ;;
  azure-kv)
    KEYTOOL_ARGS+=(--azure-vault-url "$AZURE_VAULT_URL" --azure-key-name "$AZURE_KEY_NAME" --output "$BLOB_PATH")
    ;;
  vault)
    # No --vault-token here: keytool reads VAULT_TOKEN from the environment
    # (config.applyEnv), and this whole script received it via the stdin-export
    # transport precisely to keep it out of argv/`ps` — putting it on the
    # keytool command line would undo that.
    KEYTOOL_ARGS+=(--vault-addr "$VAULT_ADDR" \
      --vault-mount-path "$VAULT_MOUNT_PATH" --vault-key-name "$VAULT_KEY_NAME")
    ;;
esac

"$SIGNER_BIN" "${KEYTOOL_ARGS[@]}" | tee /tmp/keytool.out
# `|| true`: a non-matching grep exits 1, which under pipefail+errexit would
# kill the script before the crafted error below could fire.
KEYTOOL_PUB_HEX="$(grep -F 'BLS public key (hex):' /tmp/keytool.out | awk '{print $NF}' || true)"
[[ -n "$KEYTOOL_PUB_HEX" ]] || { echo "could not parse keytool public key from output"; exit 1; }

# On a live-validator host, stop the systemd units first so they don't respawn
# and fight the test for the ports. Arm the cleanup trap here — from this point
# on, ANY exit restores the production services it stopped.
trap cleanup EXIT
# An unhandled signal skips the EXIT trap (e.g. HUP when the orchestrator's
# SSH connection drops) — convert to a plain exit so cleanup always restores
# the production services.
trap 'exit 130' INT
trap 'exit 143' TERM HUP
stop_prod_services
stop_prior_signer_node

e2e_setup_log "starting the signer (${E2E_BACKEND})"
case "$E2E_BACKEND" in
  aws-kms)
    cat > /tmp/signer.yaml <<YAML
backend: aws-kms
listen:  127.0.0.1
port:    50051
aws:
  region:                 ${AWS_REGION}
  kms_key_id:             ${KMS_KEY_ARN}
  encrypted_bls_key_path: ${BLOB_PATH}
YAML
    ;;
  gcp-kms)
    cat > /tmp/signer.yaml <<YAML
backend: gcp-kms
listen:  127.0.0.1
port:    50051
gcp:
  project:                ${GCP_PROJECT}
  location:               ${GCP_LOCATION}
  key_ring:               ${GCP_KEY_RING}
  key_name:               ${GCP_KEY_NAME}
  encrypted_bls_key_path: ${BLOB_PATH}
YAML
    ;;
  azure-kv)
    cat > /tmp/signer.yaml <<YAML
backend: azure-kv
listen:  127.0.0.1
port:    50051
azure:
  vault_url:              ${AZURE_VAULT_URL}
  key_name:               ${AZURE_KEY_NAME}
  encrypted_bls_key_path: ${BLOB_PATH}
YAML
    ;;
  vault)
    cat > /tmp/signer.yaml <<YAML
backend: vault
listen:  127.0.0.1
port:    50051
vault:
  address:     ${VAULT_ADDR}
  mount_path:  ${VAULT_MOUNT_PATH}
  key_name:    ${VAULT_KEY_NAME}
  auth_method: token
  token:       ${VAULT_TOKEN}
YAML
    ;;
esac

"$SIGNER_BIN" serve --config-file /tmp/signer.yaml >/tmp/signer.log 2>&1 &
SIGNER_PID=$!
wait_signer_listening "$SIGNER_PID"
echo "signer listening (pid $SIGNER_PID)"

verify_signer_pubkey_matches_keytool "$REPO" "$KEYTOOL_PUB_HEX" "$SIGNER_ADDR"
run_avalanchego_and_validate "$REPO" "$SIGNER_ADDR"

kill "$SIGNER_PID" 2>/dev/null || true
kill_listeners_on_port 50051
echo "remote-setup OK (${E2E_BACKEND})"
