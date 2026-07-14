#!/usr/bin/env bash
# scripts/e2e/common.sh — shared orchestrator helpers (sourced by scripts/e2e-*.sh).

e2e_log()  { printf '\033[1;34m[e2e %s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
e2e_fail() { printf '\033[1;31m[e2e FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# Resolve REPO_ROOT and RUN_ID if not set by the caller.
e2e_init_common() {
  REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  RUN_ID="${E2E_RUN_ID:-rs-e2e-$(date +%Y%m%d-%H%M%S)-$$}"
  WORKDIR="${WORKDIR:-$(mktemp -d)}"
  SSH_USER="${E2E_SSH_USER:-ubuntu}"
  NETWORK_ID="${E2E_NETWORK_ID:-fuji}"
  AVALANCHEGO_VERSION="${AVALANCHEGO_VERSION:-v1.14.0}"
}

e2e_require_host_reuse() {
  [[ -n "${E2E_HOST:-}" ]] || e2e_fail "E2E_HOST required (org policies often block VM creation — reuse an existing host)"
  [[ -n "${E2E_SSH_KEY:-}" ]] || e2e_fail "E2E_SSH_KEY required"
  [[ -f "$E2E_SSH_KEY" ]] || e2e_fail "E2E_SSH_KEY not found: $E2E_SSH_KEY"
  HOST="$E2E_HOST"
  KEYFILE="$E2E_SSH_KEY"
  chmod 600 "$KEYFILE" 2>/dev/null || true
}

e2e_wait_ssh() {
  local ssh_cmd=$1
  e2e_log "waiting for SSH to $HOST …"
  local i
  for i in $(seq 1 30); do
    $ssh_cmd "$SSH_USER@$HOST" true 2>/dev/null && return 0
    sleep 10
  done
  e2e_fail "SSH never came up on $HOST"
}

e2e_ship_repo() {
  local ssh_cmd=$1
  e2e_log "shipping repo (working tree) …"
  COPYFILE_DISABLE=1 tar -czf "$WORKDIR/repo.tgz" -C "$REPO_ROOT" \
    --exclude=.git --exclude=avalanche-remote-signer --exclude='*.enc' .
  scp -i "$KEYFILE" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "$WORKDIR/repo.tgz" "$SSH_USER@$HOST:/tmp/repo.tgz"
  $ssh_cmd "$SSH_USER@$HOST" 'mkdir -p ~/remote-signer && tar -xzf /tmp/repo.tgz -C ~/remote-signer'
}

# Run remote-setup (or another script) on the host with the given env (a
# space-separated list of KEY=VALUE, e.g. "E2E_BACKEND=vault VAULT_TOKEN=…").
# The env is `export`ed from a script fed over stdin rather than embedded in the
# ssh command string, so secrets like VAULT_TOKEN never appear in argv/`ps` on
# the laptop or the host — only `bash -s` does.
e2e_run_remote() {
  local ssh_cmd=$1
  local setup_script=$2
  shift 2
  local remote_env="$*"
  e2e_log "running ${setup_script} on $HOST …"
  local script="set -euo pipefail
cd ~/remote-signer
export E2E_RUN_ID=${RUN_ID} NETWORK_ID=${NETWORK_ID} AVALANCHEGO_VERSION=${AVALANCHEGO_VERSION}
${remote_env:+export ${remote_env}}
exec bash scripts/e2e/${setup_script}"
  if $ssh_cmd "$SSH_USER@$HOST" 'bash -s' <<<"$script"; then
    e2e_log "✅ E2E PASSED — warp + proof-of-possession signing verified end to end."
  else
    e2e_fail "❌ E2E FAILED — see the instance output above."
  fi
}

e2e_ssh_cmd() {
  echo "ssh -i $KEYFILE -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
}

# Full reuse-host flow for backends that use scripts/e2e/remote-setup.sh
e2e_run_reuse_host() {
  local backend=$1
  shift
  local extra_env="$*"
  e2e_init_common
  for bin in jq ssh scp git; do command -v "$bin" >/dev/null || e2e_fail "missing dependency: $bin"; done
  e2e_require_host_reuse
  e2e_log "backend=$backend host=$HOST run-id=$RUN_ID"
  local ssh
  ssh="$(e2e_ssh_cmd)"
  e2e_wait_ssh "$ssh"
  e2e_ship_repo "$ssh"
  e2e_run_remote "$ssh" "remote-setup.sh" "E2E_BACKEND=$backend $extra_env"
  rm -rf "$WORKDIR"
}
