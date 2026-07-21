#!/usr/bin/env bash
# One-time Vault + BLS plugin setup on a Linux host (e.g. EC2 for e2e-vault.sh).
#
# Run ON the host (not your Mac):
#   cd ~/remote-signer && bash scripts/setup-vault-host.sh
#
# Prints a VAULT_TOKEN for ./scripts/e2e-vault.sh on your laptop.
set -o errexit
set -o nounset
set -o pipefail

REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# Server paths — NOT ~/.vault (that path is used by the vault CLI token helper).
VAULT_HOME="${VAULT_HOME:-$HOME/vault-e2e}"
VAULT_CONFIG="${VAULT_CONFIG:-${VAULT_HOME}/config.hcl}"
VAULT_DATA="${VAULT_DATA:-${VAULT_HOME}/data}"
PLUGIN_DIR="${PLUGIN_DIR:-${VAULT_HOME}/plugins}"
PLUGIN_NAME="vault-plugin-bls"
MOUNT_PATH="${VAULT_MOUNT_PATH:-bls}"
GO_VERSION="${GO_VERSION:-1.25.12}"
export VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"

# `vault operator init` writes the root token + unseal key to disk; keep
# everything this script creates owner-only (dev/e2e credentials).
umask 077

log() { printf '\n=== %s ===\n' "$*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

if [[ "$(uname -s)" == "Darwin" ]]; then
  fail "This script is for Linux (EC2). On macOS use: bash scripts/setup-vault-dev-macos.sh"
fi

install_vault() {
  if command -v vault >/dev/null; then
    return 0
  fi
  log "installing Vault"
  if command -v dnf >/dev/null; then
    sudo dnf install -y yum-utils
    sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
    sudo dnf install -y vault gcc gcc-c++ make jq curl
  elif command -v apt-get >/dev/null; then
    sudo apt-get update -qq
    sudo apt-get install -y gpg curl gcc g++ make jq
    curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
      | sudo tee /etc/apt/sources.list.d/hashicorp.list
    sudo apt-get update -qq && sudo apt-get install -y vault
  else
    fail "install vault manually, then re-run"
  fi
}

install_go() {
  if command -v go >/dev/null 2>&1 && go version | grep -q "go${GO_VERSION}"; then
    return 0
  fi
  log "installing Go ${GO_VERSION}"
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tgz
  sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf /tmp/go.tgz
  export PATH="/usr/local/go/bin:$PATH"
}

write_config() {
  mkdir -p "$PLUGIN_DIR" "$VAULT_DATA" "$(dirname "$VAULT_CONFIG")"
  log "writing $VAULT_CONFIG (data: $VAULT_DATA)"
  tee "$VAULT_CONFIG" >/dev/null <<EOF
storage "file" {
  path = "${VAULT_DATA}"
}
listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = true
}
plugin_directory = "${PLUGIN_DIR}"
api_addr         = "http://127.0.0.1:8200"
disable_mlock    = true
EOF
}

start_vault() {
  if pgrep -f '[v]ault server' >/dev/null; then
    if vault status >/dev/null 2>&1; then
      log "vault server already running and unsealed — leaving it up"
      return 0
    fi
    log "stopping sealed vault server"
    pkill -f '[v]ault server' || true
    sleep 2
  fi
  # Stop packaged systemd unit if present (would bind the same ports/data).
  if command -v systemctl >/dev/null && systemctl is-active --quiet vault 2>/dev/null; then
    log "stopping systemd vault service"
    sudo systemctl stop vault || true
  fi
  log "starting vault server"
  nohup vault server -config="$VAULT_CONFIG" >/tmp/vault-server.log 2>&1 &
  # vault status exits 0 (unsealed) or 2 (sealed/uninitialized) — both mean the
  # server is up and reachable; anything else means it isn't answering yet.
  local rc
  for _ in $(seq 1 30); do
    rc=0
    vault status >/dev/null 2>&1 || rc=$?
    if [[ $rc -eq 0 || $rc -eq 2 ]]; then
      return 0
    fi
    sleep 1
  done
  echo "vault failed to start — last log lines:" >&2
  tail -30 /tmp/vault-server.log >&2 || true
  fail "vault server did not become reachable at $VAULT_ADDR"
}

init_and_unseal() {
  local status_json initialized sealed
  # vault status exits 2 while sealed/uninitialized; under pipefail that makes a
  # `... | jq ... || echo unknown` pipeline emit BOTH jq's value and "unknown".
  # Capture the JSON first, then parse.
  status_json="$(vault status -format=json 2>/dev/null || true)"
  initialized="$(jq -r '.initialized' <<<"$status_json" 2>/dev/null || echo unknown)"
  sealed="$(jq -r '.sealed' <<<"$status_json" 2>/dev/null || echo unknown)"

  if [[ "$initialized" == "false" ]]; then
    log "initializing vault (1 share / threshold 1 — dev/e2e only)"
    vault operator init -key-shares=1 -key-threshold=1 | tee /tmp/vault-init.txt
    chmod 600 /tmp/vault-init.txt # explicit: a pre-existing file keeps its old mode through tee
    initialized=true
    sealed=true
  fi

  if [[ "$initialized" == "true" && "$sealed" == "true" ]]; then
    # Initialize to empty: under `set -u` an unassigned local is unset, so a
    # missing init file would die with "unbound variable" instead of reaching
    # the crafted error below. The `|| true` keeps a non-matching grep (exit 1
    # under pipefail) from aborting before the guard can fire.
    local unseal_key="" root_token=""
    if [[ -f /tmp/vault-init.txt ]]; then
      unseal_key="$(grep -iE 'unseal key' /tmp/vault-init.txt | head -1 | sed 's/.*:[[:space:]]*//' || true)"
      root_token="$(grep -iE 'initial root token' /tmp/vault-init.txt | head -1 | sed 's/.*:[[:space:]]*//' || true)"
    fi
    [[ -n "$unseal_key" ]] || fail "vault is sealed and /tmp/vault-init.txt has no unseal key — unseal manually"
    log "unsealing vault"
    vault operator unseal "$unseal_key"
    [[ -n "$root_token" ]] && vault login "$root_token" >/dev/null
  fi

  vault status >/dev/null 2>&1 || fail "vault not ready after init/unseal (run: vault status)"
}

install_vault
command -v jq >/dev/null || sudo dnf install -y jq 2>/dev/null || sudo apt-get install -y jq 2>/dev/null || true
write_config
start_vault
init_and_unseal

log "building BLS plugin from ${REPO}/vault-plugin"
[[ -d "${REPO}/vault-plugin" ]] || fail "repo not found at ${REPO} — ship ~/remote-signer first"
install_go
export PATH="/usr/local/go/bin:${PATH:-}"
export CGO_ENABLED=1
mkdir -p "${PLUGIN_DIR}"
cd "${REPO}/vault-plugin"
go build -trimpath -o "${PLUGIN_DIR}/${PLUGIN_NAME}" .
chmod 755 "${PLUGIN_DIR}/${PLUGIN_NAME}"
[[ -f "${PLUGIN_DIR}/${PLUGIN_NAME}" ]] || fail "plugin binary missing at ${PLUGIN_DIR}/${PLUGIN_NAME}"
ls -la "${PLUGIN_DIR}/${PLUGIN_NAME}"

# Register unconditionally: the build above always produces a (potentially)
# new binary, and Vault pins plugins by SHA — keeping a stale registered SHA
# means the next plugin launch (reload, mount access after restart) fails
# checksum verification and the mount breaks. Re-registering is idempotent
# and updates the SHA in place.
SHA="$(sha256sum "${PLUGIN_DIR}/${PLUGIN_NAME}" | awk '{print $1}')"
log "registering plugin (sha256 ${SHA})"
vault plugin register -sha256="$SHA" secret vault-plugin-bls

if ! vault secrets list -format=json 2>/dev/null | jq -e ".[\"${MOUNT_PATH}/\"]" >/dev/null 2>&1; then
  log "enabling mount ${MOUNT_PATH}/"
  vault secrets enable -path="$MOUNT_PATH" vault-plugin-bls
else
  # Mount already live: reload so the running plugin process picks up the
  # rebuilt binary (and the freshly registered SHA).
  log "reloading plugin on existing mount ${MOUNT_PATH}/"
  vault plugin reload -plugin vault-plugin-bls
fi

# Unquoted heredoc so the policy tracks MOUNT_PATH — a literal "bls/" policy
# with a custom VAULT_MOUNT_PATH would 403 every call the printed token makes.
vault policy write bls-e2e - <<EOF
path "${MOUNT_PATH}/keys/+/generate"    { capabilities = ["create", "update"] }
path "${MOUNT_PATH}/keys/+/public-key"  { capabilities = ["read"] }
path "${MOUNT_PATH}/keys/+/sign"        { capabilities = ["create", "update"] }
path "${MOUNT_PATH}/keys/+/sign-pop"    { capabilities = ["create", "update"] }
EOF

E2E_TOKEN="$(vault token create -policy=bls-e2e -ttl=720h -format=json | jq -r .auth.client_token)"
[[ -n "$E2E_TOKEN" && "$E2E_TOKEN" != "null" ]] || fail "could not create E2E token"

# Print placeholders, not a real host: a copy-pasted example IP could point the
# harness at a production validator (it stops the running node/signer).
log "done — run E2E from your laptop (fill in THIS host's IP/key/user):"
cat <<EOF

E2E_HOST=<this-host-ip> E2E_SSH_KEY=<path-to-ssh-key> E2E_SSH_USER=<ssh-user> \\
VAULT_ADDR=http://127.0.0.1:8200 \\
VAULT_TOKEN=${E2E_TOKEN} \\
VAULT_KEY_NAME=validator VAULT_MOUNT_PATH=${MOUNT_PATH} \\
  ./scripts/e2e-vault.sh

EOF
