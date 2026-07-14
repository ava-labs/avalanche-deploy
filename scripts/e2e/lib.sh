#!/usr/bin/env bash
# scripts/e2e/lib.sh — shared helpers for remote E2E setup (sourced, not executed).

e2e_setup_log() { printf '\n\033[1;36m=== %s ===\033[0m\n' "$*"; }

kill_listeners_on_port() {
  local port=$1
  local pids pid
  pids=$(sudo ss -H -ltnp "sport = :${port}" 2>/dev/null \
    | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | sort -u)
  [[ -z "$pids" ]] && return 0
  while read -r pid; do
    [[ -n "$pid" ]] && sudo kill "$pid" 2>/dev/null || true
  done <<< "$pids"
  sleep 1
}

wait_port_free() {
  local port=$1
  local i
  for i in $(seq 1 15); do
    sudo ss -H -ltnp "sport = :${port}" 2>/dev/null | grep -q . || return 0
    sleep 1
  done
  echo "port ${port} still in use after stopping prior processes:" >&2
  sudo ss -ltnp "sport = :${port}" >&2 || true
  exit 1
}

install_build_deps() {
  if command -v apt-get >/dev/null; then
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq build-essential git jq curl >/dev/null
  elif command -v dnf >/dev/null; then
    local pkgs=(gcc gcc-c++ make git jq)
    command -v curl >/dev/null || pkgs+=(curl)
    sudo dnf install -y "${pkgs[@]}"
  elif command -v yum >/dev/null; then
    local pkgs=(gcc gcc-c++ make git jq)
    command -v curl >/dev/null || pkgs+=(curl)
    sudo yum install -y "${pkgs[@]}"
  else
    echo "unsupported OS: need apt-get, dnf, or yum to install build dependencies" >&2
    exit 1
  fi
}

install_go() {
  local go_version="${GO_VERSION:-1.25.12}"
  if ! command -v go >/dev/null 2>&1 || ! go version | grep -q "go${go_version}"; then
    curl -fsSL "https://go.dev/dl/go${go_version}.linux-amd64.tar.gz" -o /tmp/go.tgz
    sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf /tmp/go.tgz
  fi
  export PATH="/usr/local/go/bin:$PATH"
  export GOTOOLCHAIN=auto CGO_ENABLED=1
  go version
}

stop_prior_signer_node() {
  local signer_addr="${1:-127.0.0.1:50051}"
  local node_api="${2:-127.0.0.1:9650}"
  e2e_setup_log "stopping any prior signer / node (${signer_addr}, ${node_api})"
  kill_listeners_on_port "${signer_addr##*:}"
  kill_listeners_on_port "${node_api##*:}"
  wait_port_free "${signer_addr##*:}"
  wait_port_free "${node_api##*:}"
}

# Production systemd units stopped by stop_prod_services, in stop order (signer
# before node). restart_prod_services brings them back on exit.
E2E_STOPPED_UNITS=""

# Stop production systemd units that would otherwise fight the E2E for the
# ports / the enclave slot. Records each unit it actually stops so it can be
# restarted afterwards — the test MUST leave the validator as it found it.
stop_prod_services() {
  command -v systemctl >/dev/null || return 0
  local unit
  for unit in remote-signer avalanche-remote-signer avalanchego; do
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
      e2e_setup_log "stopping production systemd unit ${unit} (restarted on exit)"
      if sudo systemctl stop "$unit" 2>/dev/null || systemctl stop "$unit" 2>/dev/null; then
        E2E_STOPPED_UNITS="${E2E_STOPPED_UNITS:+$E2E_STOPPED_UNITS }$unit"
      fi
    fi
  done
}

# Restart the production units stop_prod_services stopped, in the same order
# (signer before node). Safe to call from an EXIT trap; never exits nonzero.
restart_prod_services() {
  [[ -n "${E2E_STOPPED_UNITS:-}" ]] || return 0
  command -v systemctl >/dev/null || return 0
  local unit
  for unit in $E2E_STOPPED_UNITS; do
    e2e_setup_log "restarting production systemd unit ${unit}"
    sudo systemctl start "$unit" 2>/dev/null || systemctl start "$unit" 2>/dev/null || \
      echo "WARNING: failed to restart ${unit} — start it manually" >&2
  done
  E2E_STOPPED_UNITS=""
}

# Best-effort enclave termination for use inside an EXIT trap: frees the enclave
# slot so a restarted production signer can claim it, and never exits nonzero
# (unlike terminate_all_nitro_enclaves, which verifies and may exit 1).
best_effort_terminate_enclaves() {
  command -v nitro-cli >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local id
  for id in $(nitro-cli describe-enclaves 2>/dev/null | jq -r '.[].EnclaveID' 2>/dev/null); do
    [[ -z "$id" || "$id" == "null" ]] && continue
    sudo nitro-cli terminate-enclave --enclave-id "$id" >/dev/null 2>&1 || true
  done
}

# Terminate every running Nitro enclave. Nitro hosts allow one enclave at a time;
# a leftover enclave at any CID causes run-enclave exit status 39.
terminate_all_nitro_enclaves() {
  if ! command -v nitro-cli >/dev/null; then
    return 0
  fi
  local ids=""
  if command -v jq >/dev/null 2>&1; then
    ids="$(nitro-cli describe-enclaves 2>/dev/null | jq -r '.[].EnclaveID' 2>/dev/null || true)"
  elif command -v python3 >/dev/null 2>&1; then
    ids="$(nitro-cli describe-enclaves 2>/dev/null | python3 -c "
import json, sys
for e in json.load(sys.stdin):
    print(e['EnclaveID'])
" 2>/dev/null || true)"
  fi
  [[ -n "$ids" ]] || return 0
  e2e_setup_log "terminating all running Nitro enclaves"
  local enclave_id
  while read -r enclave_id; do
    [[ -z "$enclave_id" || "$enclave_id" == "null" ]] && continue
    # The enclave may already be tearing itself down (the signer's shutdown
    # terminates its own enclave), in which case nitro-cli fails with a
    # spurious socket error (E11). Quiet both attempts — the verification
    # loop below is the real success check and fails loudly if anything
    # actually survives.
    nitro-cli terminate-enclave --enclave-id "$enclave_id" >/dev/null 2>&1 || \
      sudo nitro-cli terminate-enclave --enclave-id "$enclave_id" >/dev/null 2>&1 || true
  done <<< "$ids"
  local i
  for i in $(seq 1 30); do
    local remaining=""
    if command -v jq >/dev/null 2>&1; then
      remaining="$(nitro-cli describe-enclaves 2>/dev/null | jq -r '.[].EnclaveID' 2>/dev/null | head -1)"
    fi
    [[ -z "$remaining" || "$remaining" == "null" ]] && return 0
    sleep 1
  done
  echo "Nitro enclave(s) still running after terminate:" >&2
  nitro-cli describe-enclaves >&2 || true
  exit 1
}

# Terminate the enclave at a specific CID (delegates to terminate_all when any remain).
terminate_nitro_enclave_if_running() {
  terminate_all_nitro_enclaves
}

wait_signer_listening() {
  local pid=$1
  local i
  for i in $(seq 1 30); do
    (exec 3<>/dev/tcp/127.0.0.1/50051) 2>/dev/null && { exec 3>&- 3<&-; break; }
    sleep 1
    [[ $i -eq 30 ]] && { echo "signer never listened on 50051:"; cat /tmp/signer.log; exit 1; }
  done
  kill -0 "$pid" 2>/dev/null || { echo "signer process exited:"; cat /tmp/signer.log; exit 1; }
}

verify_signer_pubkey_matches_keytool() {
  local repo=$1
  local keytool_hex=$2
  local signer_addr="${3:-127.0.0.1:50051}"
  e2e_setup_log "verifying signer loaded the keytool-generated key"
  local signer_hex
  signer_hex="$(cd "$repo/tests" && go run ./e2e --signer "$signer_addr" --pubkey-hex-only)"
  if [[ "$(echo "$keytool_hex" | tr '[:upper:]' '[:lower:]')" != "$(echo "$signer_hex" | tr '[:upper:]' '[:lower:]')" ]]; then
    echo "signer public key (0x${signer_hex}) != keytool output (${keytool_hex})" >&2
    cat /tmp/signer.log >&2
    exit 1
  fi
  echo "signer public key matches keytool output (0x${signer_hex})"
}

run_avalanchego_and_validate() {
  local repo=$1
  local signer_addr=$2
  local network_id="${NETWORK_ID:-fuji}"
  local ago_version="${AVALANCHEGO_VERSION:-v1.14.0}"
  local run_id="${E2E_RUN_ID:-$(date +%Y%m%d-%H%M%S)-$$}"
  local agodata="/tmp/agodata-${run_id}"
  local node_api="127.0.0.1:9650"

  e2e_setup_log "downloading avalanchego ${ago_version}"
  curl -fsSL "https://github.com/ava-labs/avalanchego/releases/download/${ago_version}/avalanchego-linux-amd64-${ago_version}.tar.gz" -o /tmp/ago.tgz
  mkdir -p /tmp/ago && tar -xzf /tmp/ago.tgz -C /tmp/ago --strip-components=1

  e2e_setup_log "starting avalanchego with --staking-rpc-signer-endpoint=${signer_addr}"
  /tmp/ago/avalanchego \
    --network-id="$network_id" \
    --staking-rpc-signer-endpoint="$signer_addr" \
    --http-host=127.0.0.1 \
    --data-dir="$agodata" \
    --log-level=info >/tmp/agonode.log 2>&1 &
  local node_pid=$!

  e2e_setup_log "waiting for the node API + its BLS identity (info.getNodeID)"
  local node_json=""
  local i
  for i in $(seq 1 60); do
    node_json="$(curl -fsS -X POST --data '{"jsonrpc":"2.0","id":1,"method":"info.getNodeID"}' \
      -H 'content-type:application/json' "http://${node_api}/ext/info" 2>/dev/null || true)"
    echo "$node_json" | jq -e '.result.nodePOP.publicKey' >/dev/null 2>&1 && break
    sleep 5
    [[ $i -eq 60 ]] && { echo "node API/getNodeID never came up:"; tail -n 60 /tmp/agonode.log; exit 1; }
  done
  local node_id node_pub node_pop
  node_id="$(echo "$node_json"  | jq -r '.result.nodeID')"
  node_pub="$(echo "$node_json" | jq -r '.result.nodePOP.publicKey')"
  node_pop="$(echo "$node_json" | jq -r '.result.nodePOP.proofOfPossession')"
  echo "node ${node_id} is up; BLS pubkey ${node_pub}"

  e2e_setup_log "validating warp + proof-of-possession signing (tests/e2e validator)"
  cd "$repo/tests"
  go run ./e2e --signer "$signer_addr" --node-pubkey "$node_pub" --node-pop "$node_pop"

  kill "$node_pid" 2>/dev/null || true
  kill_listeners_on_port 9650
  rm -rf "$agodata"
}
