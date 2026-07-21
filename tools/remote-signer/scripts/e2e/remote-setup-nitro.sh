#!/usr/bin/env bash
# scripts/e2e/remote-setup-nitro.sh
#
# Runs ON a Nitro-enabled Amazon Linux host. Builds signer + enclave EIF (optional),
# starts aws-nitro backend, avalanchego, and tests/e2e.
#
# Required: AWS_REGION, KMS_KEY_ARN (or E2E_KMS_KEY_ARN)
# Optional: E2E_EIF_PATH (default ~/remote-signer.eif), E2E_SKIP_EIF_REBUILD=1 to reuse EIF
set -o errexit
set -o nounset
set -o pipefail

AWS_REGION="${AWS_REGION:?AWS_REGION required}"
KMS_KEY_ARN="${KMS_KEY_ARN:-${E2E_KMS_KEY_ARN:?KMS_KEY_ARN or E2E_KMS_KEY_ARN required}}"
REPO="${REPO:-$HOME/remote-signer}"
SIGNER_ADDR="127.0.0.1:50051"
SIGNER_BIN="/tmp/avalanche-remote-signer"
BLOB_PATH="/tmp/bls.key.enc"
# Default EIF path depends on mode: reuse mode points at the deployed EIF, but a
# rebuild writes to a SEPARATE file so it can never clobber a production EIF
# (the key blob is baked into the EIF — overwriting it would silently change
# the validator's BLS identity on next restart).
if [[ "${E2E_SKIP_EIF_REBUILD:-0}" == "1" ]]; then
  EIF_PATH="${E2E_EIF_PATH:-$HOME/remote-signer.eif}"
else
  EIF_PATH="${E2E_EIF_PATH:-$HOME/remote-signer-e2e.eif}"
fi
ENCLAVE_CID="${E2E_ENCLAVE_CID:-16}"
CPU_COUNT="${E2E_NITRO_CPU_COUNT:-2}"
MEMORY_MIB="${E2E_NITRO_MEMORY_MIB:-512}"
KMS_REGION="${AWS_REGION}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

umask 077 # the signer config may hold secrets — keep created files owner-only

# Restore production services + clean up test processes/enclaves on ANY exit.
# Armed below, right before the first stop/kill — an early exit (bad args, the
# EIF guard) must not touch a live host.
cleanup() {
  set +e
  [[ -n "${SIGNER_PID:-}" ]] && kill "$SIGNER_PID" 2>/dev/null
  kill_listeners_on_port 50051
  kill_listeners_on_port 9650
  best_effort_terminate_enclaves
  rm -f /tmp/signer.yaml
  restart_prod_services
}

if ! command -v nitro-cli >/dev/null; then
  echo "nitro-cli not found — use Amazon Linux 2023 with Nitro Enclaves enabled (see docs/aws-nitro.md)" >&2
  exit 1
fi

# In rebuild mode we build a fresh EIF (with a fresh key) at EIF_PATH. Refuse to
# overwrite an existing EIF: its baked-in key means overwriting could silently
# change a validator's BLS identity on the next restart. Checked before any
# service is stopped, so this failure leaves the host untouched.
if [[ "${E2E_SKIP_EIF_REBUILD:-0}" != "1" && -e "$EIF_PATH" && "${E2E_ALLOW_EIF_OVERWRITE:-0}" != "1" ]]; then
  echo "refusing to overwrite existing EIF at $EIF_PATH" >&2
  echo "  reuse it with E2E_SKIP_EIF_REBUILD=1, choose a new E2E_EIF_PATH, or force with E2E_ALLOW_EIF_OVERWRITE=1" >&2
  exit 1
fi

e2e_setup_log "installing dependencies"
install_build_deps
install_go

# vsock-proxy for enclave → KMS (idempotent)
if ! pgrep -f 'vsock-proxy 8443' >/dev/null 2>&1; then
  e2e_setup_log "starting vsock-proxy for KMS"
  nohup vsock-proxy 8443 "kms.${KMS_REGION}.amazonaws.com" 443 >/tmp/vsock-proxy.log 2>&1 &
  sleep 2
fi

e2e_setup_log "building the signer"
cd "$REPO"
go build -o "$SIGNER_BIN" ./main/

# From here on we stop/kill things — arm the cleanup trap so ANY exit restores
# the production services and frees the enclave slot.
trap cleanup EXIT
# An unhandled signal skips the EXIT trap (e.g. HUP when the orchestrator's
# SSH connection drops) — convert to a plain exit so cleanup always runs.
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# Stop any prior signer/node, production services, and stale enclaves.
stop_prod_services
stop_prior_signer_node
terminate_all_nitro_enclaves

# The blob is baked into the EIF at build time, so a fresh key is only
# meaningful when we rebuild. In reuse mode the enclave signs with whatever
# key its EIF already contains — generating (and match-checking) a new one
# would always fail.
KEYTOOL_PUB_HEX=""
if [[ "${E2E_SKIP_EIF_REBUILD:-0}" == "1" ]]; then
  e2e_setup_log "E2E_SKIP_EIF_REBUILD=1 — reusing ${EIF_PATH}; signer identity comes from the key baked into that EIF"
else
  e2e_setup_log "generating KMS-encrypted BLS key for the enclave"
  "$SIGNER_BIN" keytool generate \
    --backend aws-kms --aws-region "$AWS_REGION" --aws-kms-key-id "$KMS_KEY_ARN" \
    --output "$BLOB_PATH" | tee /tmp/keytool.out
  # `|| true`: a non-matching grep exits 1, which under pipefail+errexit would
  # kill the script before the crafted error below could fire.
  KEYTOOL_PUB_HEX="$(grep -F 'BLS public key (hex):' /tmp/keytool.out | awk '{print $NF}' || true)"
  [[ -n "$KEYTOOL_PUB_HEX" ]] || { echo "could not parse keytool public key"; exit 1; }
fi

if [[ "${E2E_SKIP_EIF_REBUILD:-0}" != "1" ]]; then
  e2e_setup_log "building enclave EIF at ${EIF_PATH} (slow — set E2E_SKIP_EIF_REBUILD=1 to reuse existing EIF)"
  command -v docker >/dev/null || { echo "docker required to build EIF"; exit 1; }
  sudo dnf install -y glibc-static aws-nitro-enclaves-cli-devel 2>/dev/null || \
    sudo yum install -y glibc-static aws-nitro-enclaves-cli-devel
  cd "$REPO/enclave"
  CGO_ENABLED=1 go build -ldflags="-linkmode external -extldflags '-static'" -o enclave-bin .
  cp "$BLOB_PATH" ./bls.key.enc
  docker build \
    --build-arg KMS_KEY_ID="$KMS_KEY_ARN" \
    -t remote-signer-enclave .
  nitro-cli build-enclave --docker-uri remote-signer-enclave --output-file "$EIF_PATH"
fi
[[ -f "$EIF_PATH" ]] || { echo "EIF not found at $EIF_PATH — unset E2E_SKIP_EIF_REBUILD or build manually"; exit 1; }

stop_prod_services
stop_prior_signer_node
terminate_all_nitro_enclaves
sleep 3

e2e_setup_log "starting signer (aws-nitro)"
cat > /tmp/signer.yaml <<YAML
backend: aws-nitro
listen:  127.0.0.1
port:    50051
nitro:
  region:                 ${AWS_REGION}
  eif_path:               ${EIF_PATH}
  kms_key_id:             ${KMS_KEY_ARN}
  encrypted_bls_key_path: ${BLOB_PATH}
  cpu_count:              ${CPU_COUNT}
  memory_mib:             ${MEMORY_MIB}
  enclave_cid:            ${ENCLAVE_CID}
YAML

"$SIGNER_BIN" serve --config-file /tmp/signer.yaml >/tmp/signer.log 2>&1 &
SIGNER_PID=$!
wait_signer_listening "$SIGNER_PID"
echo "signer listening (pid $SIGNER_PID)"

if [[ -n "$KEYTOOL_PUB_HEX" ]]; then
  verify_signer_pubkey_matches_keytool "$REPO" "$KEYTOOL_PUB_HEX" "$SIGNER_ADDR"
else
  e2e_setup_log "skipping keytool match (reused EIF) — validator still verifies signing end to end"
fi
run_avalanchego_and_validate "$REPO" "$SIGNER_ADDR"

kill "$SIGNER_PID" 2>/dev/null || true
kill_listeners_on_port 50051
terminate_all_nitro_enclaves
echo "remote-setup-nitro OK"
