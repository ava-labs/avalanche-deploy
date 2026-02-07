#!/usr/bin/env bash
# Create an Avalanche L1 from Kubernetes L1 validator pods.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Defaults
NETWORK="fuji"
CHAIN_NAME="mychain"
RELEASE="l1-validators"
OUTPUT="l1.env"
GENESIS=""
KEY_NAME=""

usage() {
    cat <<USAGE
Usage: $0 [options]
  --network=fuji|mainnet   Network (default: fuji)
  --chain-name=NAME        Chain name (default: mychain)
  --release=NAME           Helm release name for L1 validators (default: l1-validators)
  --genesis=FILE           Genesis file (default: auto-find)
  --output=FILE            Output file (default: l1.env)
  --key-name=NAME          platform-cli key name (optional; otherwise uses default key or env fallback)
  -h, --help               Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --network=*) NETWORK="${1#*=}"; shift ;;
        --chain-name=*) CHAIN_NAME="${1#*=}"; shift ;;
        --release=*) RELEASE="${1#*=}"; shift ;;
        --genesis=*) GENESIS="${1#*=}"; shift ;;
        --output=*) OUTPUT="${1#*=}"; shift ;;
        --key-name=*) KEY_NAME="${1#*=}"; shift ;;
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

CREATE_L1="$ROOT_DIR/tools/create-l1/create-l1"

needs_build=false
if [[ ! -x "$CREATE_L1" ]]; then
    needs_build=true
elif [[ "$ROOT_DIR/tools/create-l1/main.go" -nt "$CREATE_L1" ]]; then
    needs_build=true
elif [[ "$ROOT_DIR/tools/create-l1/go.mod" -nt "$CREATE_L1" ]]; then
    needs_build=true
elif [[ -f "$ROOT_DIR/tools/create-l1/go.sum" && "$ROOT_DIR/tools/create-l1/go.sum" -nt "$CREATE_L1" ]]; then
    needs_build=true
elif ! "$CREATE_L1" --help 2>&1 | grep -q -- "-key-name"; then
    # Existing binary is from an older build and doesn't support key manager flow.
    needs_build=true
fi

if [[ "$needs_build" == "true" ]]; then
    echo "Building create-l1 tool..."
    (cd "$ROOT_DIR/tools/create-l1" && go build -o create-l1 .)
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "Error: curl not found in PATH"
    exit 1
fi

echo "Getting running L1 validator pods for release '$RELEASE'..."
PODS="$(kubectl get pods \
    -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/name=l1-validator" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[*].metadata.name}')"

if [[ -z "$PODS" ]]; then
    echo "No running L1 validator pods found for release: $RELEASE"
    echo "Deploy first, for example:"
    echo "  helm upgrade --install $RELEASE \"$ROOT_DIR/kubernetes/helm/avalanche-validator\" -f \"$ROOT_DIR/kubernetes/helm/avalanche-validator/values-kind.yaml\" --set network=$NETWORK"
    exit 1
fi

REAL_VALIDATOR_IPS=""
for pod in $PODS; do
    ip="$(kubectl get pod "$pod" -o jsonpath='{.status.podIP}')"
    if [[ -n "$REAL_VALIDATOR_IPS" ]]; then
        REAL_VALIDATOR_IPS="$REAL_VALIDATOR_IPS,$ip"
    else
        REAL_VALIDATOR_IPS="$ip"
    fi
done

echo "Validator Pods: $REAL_VALIDATOR_IPS"

if [[ -z "$GENESIS" ]]; then
    if [[ -f "$ROOT_DIR/configs/l1/genesis/genesis.json" ]]; then
        GENESIS="$ROOT_DIR/configs/l1/genesis/genesis.json"
    elif [[ -f "$ROOT_DIR/genesis.json" ]]; then
        # Backward-compatible fallback for older checkouts.
        GENESIS="$ROOT_DIR/genesis.json"
    else
        echo "Error: no genesis file found. Create configs/l1/genesis/genesis.json."
        exit 1
    fi
fi

echo "Genesis: $GENESIS"
echo "Network: $NETWORK"
echo "Chain Name: $CHAIN_NAME"
if [[ -n "$KEY_NAME" ]]; then
    echo "Key Source: platform-cli key '$KEY_NAME'"
else
    echo "Key Source: platform-cli default key (or AVALANCHE_PRIVATE_KEY fallback)"
fi
echo ""

PF_PIDS=()
VALIDATOR_IPS=""
validator_index=0

wait_for_node_id() {
    local endpoint="$1"
    local response=""

    for _ in $(seq 1 30); do
        response="$(curl --noproxy '*' -s "http://${endpoint}/ext/info" \
            -X POST -H 'content-type:application/json' \
            -d '{"jsonrpc":"2.0","id":1,"method":"info.getNodeID"}' 2>/dev/null || true)"
        if [[ "$response" == *'"nodeID"'* ]]; then
            return 0
        fi
        sleep 0.25
    done
    return 1
}

cleanup() {
    for pid in "${PF_PIDS[@]:-}"; do
        kill "$pid" >/dev/null 2>&1 || true
        wait "$pid" >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT

for pod in $PODS; do
    local_port="$((19650 + validator_index))"
    local_endpoint="127.0.0.1:${local_port}"
    echo "Setting up temporary port-forward to $pod on ${local_endpoint}..."
    kubectl port-forward --address 127.0.0.1 "pod/$pod" "${local_port}:9650" >/dev/null 2>&1 &
    PF_PIDS+=("$!")
    validator_index=$((validator_index + 1))

    if [[ -n "$VALIDATOR_IPS" ]]; then
        VALIDATOR_IPS="$VALIDATOR_IPS,$local_endpoint"
    else
        VALIDATOR_IPS="$local_endpoint"
    fi
done

echo "Validator API Endpoints: $VALIDATOR_IPS"
for endpoint in ${VALIDATOR_IPS//,/ }; do
    if ! wait_for_node_id "$endpoint"; then
        echo "Error: failed to reach validator API at $endpoint"
        exit 1
    fi
done

echo "Creating L1..."
create_l1_args=(
    --network="$NETWORK"
    --validators="$VALIDATOR_IPS"
    --chain-name="$CHAIN_NAME"
    --genesis="$GENESIS"
    --output="$OUTPUT"
)
if [[ -n "$KEY_NAME" ]]; then
    create_l1_args+=(--key-name="$KEY_NAME")
fi

"$CREATE_L1" \
    "${create_l1_args[@]}"

echo ""
echo "L1 created. Config saved to: $OUTPUT"
echo "Next: \"$SCRIPT_DIR/configure-l1.sh\" --release=$RELEASE --env=$OUTPUT"
