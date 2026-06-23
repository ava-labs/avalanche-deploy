#!/usr/bin/env bash
# scripts/e2e/remote-setup.sh
#
# Runs ON the EC2 instance, invoked over SSH by scripts/e2e-aws.sh. It:
#   1. installs build deps + Go
#   2. builds the signer and generates a KMS-encrypted BLS key (aws-kms backend,
#      using the instance profile's kms:Encrypt — no static credentials)
#   3. starts the signer, then starts avalanchego with
#      --staking-rpc-signer-endpoint pointed at it
#   4. reads the node's BLS identity (info.getNodeID) and runs the tests/e2e
#      validator to verify warp + proof-of-possession signing end to end
#
# Inputs (env): AWS_REGION, KMS_KEY_ARN  (required); NETWORK_ID,
# AVALANCHEGO_VERSION, GO_VERSION (optional). Exits non-zero on any failure.
set -o errexit
set -o nounset
set -o pipefail

: "${AWS_REGION:?AWS_REGION required}"
: "${KMS_KEY_ARN:?KMS_KEY_ARN required}"
NETWORK_ID="${NETWORK_ID:-fuji}"
AVALANCHEGO_VERSION="${AVALANCHEGO_VERSION:-v1.14.0}"
GO_VERSION="${GO_VERSION:-1.25.8}"   # matches tests/go.mod; override if unavailable
RUN_ID="${E2E_RUN_ID:-$(date +%Y%m%d-%H%M%S)-$$}"
SIGNER_ADDR="127.0.0.1:50051"
NODE_API="127.0.0.1:9650"
AGODATA="/tmp/agodata-${RUN_ID}"
REPO="$HOME/remote-signer"

log() { printf '\n\033[1;36m=== %s ===\033[0m\n' "$*"; }

# Kill whatever is listening on a TCP port (needed on reused EC2 hosts).
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
    # AL2023 ships curl-minimal; installing curl conflicts with it.
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

log "installing dependencies"
install_build_deps
if ! command -v go >/dev/null 2>&1 || ! go version | grep -q "go${GO_VERSION}"; then
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tgz
  sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf /tmp/go.tgz
fi
export PATH="/usr/local/go/bin:$PATH"
export GOTOOLCHAIN=auto CGO_ENABLED=1   # CGO required (blst); auto-fetch toolchain if a module needs newer
go version

log "building the signer"
cd "$REPO"
go build -o /tmp/remote-signer ./main/

log "generating a KMS-encrypted BLS key (keytool generate, aws-kms)"
/tmp/remote-signer keytool generate \
  --backend aws-kms --aws-region "$AWS_REGION" --aws-kms-key-id "$KMS_KEY_ARN" \
  --output /tmp/bls.key.enc | tee /tmp/keytool.out
KEYTOOL_PUB_HEX="$(grep -F 'BLS public key (hex):' /tmp/keytool.out | awk '{print $NF}')"
[[ -n "$KEYTOOL_PUB_HEX" ]] || { echo "could not parse keytool public key from output"; exit 1; }

log "stopping any prior signer / node (${SIGNER_ADDR}, ${NODE_API})"
kill_listeners_on_port 50051
kill_listeners_on_port 9650
wait_port_free 50051
wait_port_free 9650

log "starting the signer"
cat > /tmp/signer.yaml <<YAML
backend: aws-kms
listen:  127.0.0.1
port:    50051
aws:
  region:                 ${AWS_REGION}
  kms_key_id:             ${KMS_KEY_ARN}
  encrypted_bls_key_path: /tmp/bls.key.enc
YAML
/tmp/remote-signer serve --config-file /tmp/signer.yaml >/tmp/signer.log 2>&1 &
SIGNER_PID=$!
for i in $(seq 1 30); do
  (exec 3<>/dev/tcp/127.0.0.1/50051) 2>/dev/null && { exec 3>&- 3<&-; break; }
  sleep 1
  [[ $i -eq 30 ]] && { echo "signer never listened on 50051:"; cat /tmp/signer.log; exit 1; }
done
kill -0 "$SIGNER_PID" 2>/dev/null || { echo "signer process exited:"; cat /tmp/signer.log; exit 1; }
echo "signer listening (pid $SIGNER_PID)"

log "verifying signer loaded the keytool-generated key"
SIGNER_PUB_HEX="$(cd "$REPO/tests" && go run ./e2e --signer "$SIGNER_ADDR" --pubkey-hex-only)"
if [[ "$(echo "$KEYTOOL_PUB_HEX" | tr '[:upper:]' '[:lower:]')" != "$(echo "$SIGNER_PUB_HEX" | tr '[:upper:]' '[:lower:]')" ]]; then
  echo "signer public key (0x${SIGNER_PUB_HEX}) != keytool output (${KEYTOOL_PUB_HEX})" >&2
  echo "see /tmp/signer.log:" >&2
  cat /tmp/signer.log >&2
  exit 1
fi
echo "signer public key matches keytool output (0x${SIGNER_PUB_HEX})"

log "downloading avalanchego ${AVALANCHEGO_VERSION}"
curl -fsSL "https://github.com/ava-labs/avalanchego/releases/download/${AVALANCHEGO_VERSION}/avalanchego-linux-amd64-${AVALANCHEGO_VERSION}.tar.gz" -o /tmp/ago.tgz
mkdir -p /tmp/ago && tar -xzf /tmp/ago.tgz -C /tmp/ago --strip-components=1

log "starting avalanchego with --staking-rpc-signer-endpoint=${SIGNER_ADDR}"
/tmp/ago/avalanchego \
  --network-id="$NETWORK_ID" \
  --staking-rpc-signer-endpoint="$SIGNER_ADDR" \
  --http-host=127.0.0.1 \
  --data-dir="$AGODATA" \
  --log-level=info >/tmp/agonode.log 2>&1 &
NODE_PID=$!

log "waiting for the node API + its BLS identity (info.getNodeID)"
NODE_JSON=""
for i in $(seq 1 60); do
  NODE_JSON="$(curl -fsS -X POST --data '{"jsonrpc":"2.0","id":1,"method":"info.getNodeID"}' \
    -H 'content-type:application/json' "http://${NODE_API}/ext/info" 2>/dev/null || true)"
  echo "$NODE_JSON" | jq -e '.result.nodePOP.publicKey' >/dev/null 2>&1 && break
  sleep 5
  [[ $i -eq 60 ]] && { echo "node API/getNodeID never came up:"; tail -n 60 /tmp/agonode.log; exit 1; }
done
NODE_ID="$(echo "$NODE_JSON"  | jq -r '.result.nodeID')"
NODE_PUB="$(echo "$NODE_JSON" | jq -r '.result.nodePOP.publicKey')"
NODE_POP="$(echo "$NODE_JSON" | jq -r '.result.nodePOP.proofOfPossession')"
echo "node ${NODE_ID} is up; BLS pubkey ${NODE_PUB}"

log "validating warp + proof-of-possession signing (tests/e2e validator)"
cd "$REPO/tests"
go run ./e2e --signer "$SIGNER_ADDR" --node-pubkey "$NODE_PUB" --node-pop "$NODE_POP"

log "cleaning up node + signer processes"
kill "$NODE_PID" "$SIGNER_PID" 2>/dev/null || true
kill_listeners_on_port 50051
kill_listeners_on_port 9650
rm -rf "$AGODATA"
echo "remote-setup OK"
