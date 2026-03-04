#!/usr/bin/env bash
# Initialize ValidatorManager contract on an Avalanche L1 via Kubernetes.
#
# This script:
#   1. Port-forwards to an RPC pod to get a local RPC endpoint
#   2. Builds the initialize-validator-manager Go tool if needed
#   3. Runs the tool to deploy and initialize the ValidatorManager contract
#
# Prerequisites:
#   - L1 must be created and configured (create-l1.sh + configure-l1.sh)
#   - Foundry (forge/cast) installed
#   - AVALANCHE_PRIVATE_KEY env var set
#   - Go 1.21+ (for building the tool)
#
# Usage:
#   ./init-validator-manager.sh \
#     --subnet-id=xxx \
#     --chain-id=yyy \
#     --conversion-tx=zzz \
#     --proxy-address=0x... \
#     --evm-chain-id=99999
#
#   # Or load from l1.env:
#   source l1.env
#   ./init-validator-manager.sh \
#     --subnet-id=$SUBNET_ID \
#     --chain-id=$CHAIN_ID \
#     --conversion-tx=$CONVERSION_TX \
#     --proxy-address=0x... \
#     --evm-chain-id=99999
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Defaults
RELEASE="l1-validators"
SUBNET_ID=""
CHAIN_ID=""
CONVERSION_TX=""
PROXY_ADDRESS=""
EVM_CHAIN_ID=""
MANAGER_TYPE="poa"
NETWORK="fuji"
CHURN_PERIOD="0"
MAX_CHURN_PERCENT="20"
ICM_CONTRACTS_PATH="${ICM_CONTRACTS_PATH:-}"
GLACIER_API_KEY="${GLACIER_API_KEY:-}"
USE_LOCAL_SIG_AGG="false"
OUTPUT="$ROOT_DIR/validator-manager.json"

usage() {
    cat <<USAGE
Usage: $0 [options]

Required:
  --subnet-id=ID           L1 subnet ID (from create-l1 output)
  --chain-id=ID            L1 blockchain ID (from create-l1 output)
  --conversion-tx=HASH     ConvertSubnetToL1Tx hash (from create-l1 output)
  --proxy-address=ADDR     Genesis proxy address for validator manager
  --evm-chain-id=ID        EVM chain ID (from genesis config.chainId)

Optional:
  --release=NAME           Helm release name for validators (default: l1-validators)
  --manager-type=TYPE      poa, native-staking, or erc20-staking (default: poa)
  --network=NAME           fuji or mainnet (default: fuji)
  --churn-period=SECS      Churn period in seconds (default: 0)
  --max-churn-percent=PCT  Maximum churn percentage (default: 20)
  --contracts-path=PATH    Path to icm-contracts repository
  --glacier-api-key=KEY    Glacier API key for signature aggregation
  --local-sig-agg          Use local signature aggregator instead of Glacier
  --output=FILE            Output JSON file (default: validator-manager.json)
  -h, --help               Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --subnet-id=*) SUBNET_ID="${1#*=}"; shift ;;
        --chain-id=*) CHAIN_ID="${1#*=}"; shift ;;
        --conversion-tx=*) CONVERSION_TX="${1#*=}"; shift ;;
        --proxy-address=*) PROXY_ADDRESS="${1#*=}"; shift ;;
        --evm-chain-id=*) EVM_CHAIN_ID="${1#*=}"; shift ;;
        --release=*) RELEASE="${1#*=}"; shift ;;
        --manager-type=*) MANAGER_TYPE="${1#*=}"; shift ;;
        --network=*) NETWORK="${1#*=}"; shift ;;
        --churn-period=*) CHURN_PERIOD="${1#*=}"; shift ;;
        --max-churn-percent=*) MAX_CHURN_PERCENT="${1#*=}"; shift ;;
        --contracts-path=*) ICM_CONTRACTS_PATH="${1#*=}"; shift ;;
        --glacier-api-key=*) GLACIER_API_KEY="${1#*=}"; shift ;;
        --local-sig-agg) USE_LOCAL_SIG_AGG="true"; shift ;;
        --output=*) OUTPUT="${1#*=}"; shift ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Colors
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[1;33m'
reset='\033[0m'

# --- Validate required parameters ---

missing=()
[[ -z "$SUBNET_ID" ]] && missing+=("--subnet-id")
[[ -z "$CHAIN_ID" ]] && missing+=("--chain-id")
[[ -z "$CONVERSION_TX" ]] && missing+=("--conversion-tx")
[[ -z "$PROXY_ADDRESS" ]] && missing+=("--proxy-address")
[[ -z "$EVM_CHAIN_ID" ]] && missing+=("--evm-chain-id")

if [[ ${#missing[@]} -gt 0 ]]; then
    echo -e "${red}Error: Missing required parameters: ${missing[*]}${reset}"
    echo ""
    usage
    exit 1
fi

# --- Check prerequisites ---

echo "Checking prerequisites..."

if [[ -z "${AVALANCHE_PRIVATE_KEY:-}" ]]; then
    echo -e "${red}Error: AVALANCHE_PRIVATE_KEY environment variable is required${reset}"
    exit 1
fi

for cmd in kubectl curl forge cast go; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo -e "${red}Error: $cmd not found in PATH${reset}"
        if [[ "$cmd" == "forge" || "$cmd" == "cast" ]]; then
            echo "  Install Foundry: curl -L https://foundry.paradigm.xyz | bash && foundryup"
        fi
        exit 1
    fi
done

echo -e "  ${green}OK${reset}"
echo ""

# --- Build tool if needed ---

TOOL_BIN="$ROOT_DIR/tools/initialize-validator-manager/initialize-validator-manager"

needs_build=false
if [[ ! -x "$TOOL_BIN" ]]; then
    needs_build=true
elif [[ "$ROOT_DIR/tools/initialize-validator-manager/main.go" -nt "$TOOL_BIN" ]]; then
    needs_build=true
elif [[ "$ROOT_DIR/tools/initialize-validator-manager/go.mod" -nt "$TOOL_BIN" ]]; then
    needs_build=true
fi

if [[ "$needs_build" == "true" ]]; then
    echo "Building initialize-validator-manager tool..."
    (cd "$ROOT_DIR/tools/initialize-validator-manager" && go build -o initialize-validator-manager .)
    echo -e "  ${green}Built${reset}"
    echo ""
fi

# --- Get validator IPs ---

echo "Getting validator pod IPs..."

PODS="$(kubectl get pods \
    -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/name=l1-validator" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[*].metadata.name}')"

if [[ -z "$PODS" ]]; then
    echo -e "${red}No running validator pods found for release: $RELEASE${reset}"
    exit 1
fi

VALIDATOR_IPS=""
for pod in $PODS; do
    ip="$(kubectl get pod "$pod" -o jsonpath='{.status.podIP}')"
    if [[ -n "$VALIDATOR_IPS" ]]; then
        VALIDATOR_IPS="$VALIDATOR_IPS,$ip"
    else
        VALIDATOR_IPS="$ip"
    fi
    echo "  $pod: $ip"
done

echo ""

# --- Port-forward to RPC pod ---

echo "Setting up port-forward to RPC pod..."

# Use the first validator pod as the RPC endpoint
first_pod="$(echo "$PODS" | awk '{print $1}')"
PF_PORT="$((19650 + RANDOM % 1000))"

kubectl port-forward --address 127.0.0.1 "pod/$first_pod" "${PF_PORT}:9650" >/dev/null 2>&1 &
PF_PID=$!

cleanup() {
    kill "$PF_PID" >/dev/null 2>&1 || true
    wait "$PF_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Wait for port-forward to be ready
RPC_URL="http://127.0.0.1:${PF_PORT}/ext/bc/${CHAIN_ID}/rpc"

for _ in $(seq 1 30); do
    response="$(curl -s "http://127.0.0.1:${PF_PORT}/ext/info" \
        -X POST -H 'content-type:application/json' \
        -d '{"jsonrpc":"2.0","id":1,"method":"info.getNodeID"}' 2>/dev/null || true)"
    if [[ -n "$response" ]]; then
        break
    fi
    sleep 0.25
done

if [[ -z "$response" ]]; then
    echo -e "${red}Error: failed to connect to pod $first_pod on port $PF_PORT${reset}"
    exit 1
fi

echo "  RPC URL: $RPC_URL"
echo ""

# --- Verify L1 chain is ready ---

echo "Verifying L1 chain is ready..."

chain_check="$(curl -s "$RPC_URL" \
    -X POST -H 'content-type:application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' 2>/dev/null || true)"

chain_result="$(echo "$chain_check" | sed -n 's/.*"result":"\([^"]*\)".*/\1/p')"

if [[ -z "$chain_result" ]]; then
    echo -e "${red}Error: L1 chain is not responding on $RPC_URL${reset}"
    echo "Make sure the L1 is configured and synced (run configure-l1.sh first)."
    exit 1
fi

reported_chain_id="$((chain_result))"
if [[ "$reported_chain_id" -ne "$EVM_CHAIN_ID" ]]; then
    echo -e "${red}Error: Chain ID mismatch - expected $EVM_CHAIN_ID, got $reported_chain_id${reset}"
    exit 1
fi

echo -e "  L1 chain ready (EVM chainId: $reported_chain_id)"
echo ""

# --- Display configuration ---

echo "============================================"
echo "  ValidatorManager Initialization"
echo "============================================"
echo ""
echo "  Network:        $NETWORK"
echo "  RPC URL:        $RPC_URL"
echo "  Subnet ID:      $SUBNET_ID"
echo "  Chain ID:       $CHAIN_ID"
echo "  EVM Chain ID:   $EVM_CHAIN_ID"
echo "  Proxy Address:  $PROXY_ADDRESS"
echo "  Manager Type:   $MANAGER_TYPE"
echo "  Conversion TX:  $CONVERSION_TX"
echo "  Validator IPs:  $VALIDATOR_IPS"
echo "  Output:         $OUTPUT"
echo ""

# --- Run the tool ---

echo "Running initialize-validator-manager..."
echo ""

init_args=(
    --rpc-url="$RPC_URL"
    --proxy-address="$PROXY_ADDRESS"
    --subnet-id="$SUBNET_ID"
    --chain-id="$CHAIN_ID"
    --conversion-tx="$CONVERSION_TX"
    --manager-type="$MANAGER_TYPE"
    --network="$NETWORK"
    --validator-ips="$VALIDATOR_IPS"
    --churn-period="$CHURN_PERIOD"
    --max-churn-percent="$MAX_CHURN_PERCENT"
    --output="$OUTPUT"
    --json
)

if [[ -n "$ICM_CONTRACTS_PATH" ]]; then
    init_args+=(--contracts-path="$ICM_CONTRACTS_PATH")
fi

if [[ "$USE_LOCAL_SIG_AGG" == "true" ]]; then
    init_args+=(--local-sig-agg)
fi

if [[ -n "$GLACIER_API_KEY" ]]; then
    init_args+=(--glacier-api-key="$GLACIER_API_KEY")
fi

INIT_OUTPUT="$("$TOOL_BIN" "${init_args[@]}")"
INIT_EXIT=$?

if [[ $INIT_EXIT -ne 0 ]]; then
    echo -e "${red}Error: initialize-validator-manager failed (exit code $INIT_EXIT)${reset}"
    echo "$INIT_OUTPUT"
    exit 1
fi

echo "$INIT_OUTPUT"
echo ""

# --- Parse and display results ---

# Try to extract key fields from JSON output
implementation="$(echo "$INIT_OUTPUT" | sed -n 's/.*"implementation":"\([^"]*\)".*/\1/p')"
proxy="$(echo "$INIT_OUTPUT" | sed -n 's/.*"proxy":"\([^"]*\)".*/\1/p')"

echo "============================================"
echo -e "  ${green}ValidatorManager Initialized!${reset}"
echo "============================================"
echo ""
if [[ -n "$implementation" ]]; then
    echo "  Implementation: $implementation"
fi
if [[ -n "$proxy" ]]; then
    echo "  Proxy:          $proxy"
fi
echo "  Output saved:   $OUTPUT"
echo ""
echo "  Your L1 validator manager is now active!"
if [[ "$MANAGER_TYPE" == "poa" ]]; then
    echo ""
    echo "  PoA Manager Commands:"
    echo "    - Add validator:    call PoAManager.initializeValidatorRegistration()"
    echo "    - Remove validator: call PoAManager.initializeEndValidation()"
fi
echo ""
echo "============================================"
