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

usage() {
    cat <<USAGE
Usage: $0 [options]
  --network=fuji|mainnet   Network (default: fuji)
  --chain-name=NAME        Chain name (default: mychain)
  --release=NAME           Helm release name for L1 validators (default: l1-validators)
  --genesis=FILE           Genesis file (default: auto-find)
  --output=FILE            Output file (default: l1.env)
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

if [[ -z "${AVALANCHE_PRIVATE_KEY:-}" ]]; then
    echo "Error: AVALANCHE_PRIVATE_KEY not set"
    echo "Export your funded P-Chain private key:"
    echo "  export AVALANCHE_PRIVATE_KEY=\"PrivateKey-...\""
    exit 1
fi

CREATE_L1="$ROOT_DIR/tools/create-l1/create-l1"
if [[ ! -f "$CREATE_L1" ]]; then
    echo "Building create-l1 tool..."
    (cd "$ROOT_DIR/tools/create-l1" && go build -o create-l1 .)
fi

echo "Getting L1 validator pod IPs for release '$RELEASE'..."
PODS="$(kubectl get pods -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/name=l1-validator" -o jsonpath='{.items[*].metadata.name}')"

if [[ -z "$PODS" ]]; then
    echo "No L1 validator pods found for release: $RELEASE"
    echo "Deploy first, for example:"
    echo "  helm install $RELEASE ./helm/avalanche-validator --set l1_validator_replicas=3 --set network=$NETWORK"
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
done

echo "Validators: $VALIDATOR_IPS"

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
echo ""

first_pod="${PODS%% *}"
echo "Setting up temporary port-forward to $first_pod..."
kubectl port-forward "pod/$first_pod" 19650:9650 >/dev/null 2>&1 &
pf_pid=$!
sleep 3

cleanup() {
    kill "$pf_pid" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Creating L1..."
"$CREATE_L1" \
    --network="$NETWORK" \
    --validators="$VALIDATOR_IPS" \
    --chain-name="$CHAIN_NAME" \
    --genesis="$GENESIS" \
    --output="$OUTPUT"

echo ""
echo "L1 created. Config saved to: $OUTPUT"
echo "Next: ./scripts/configure-l1.sh --release=$RELEASE --env=$OUTPUT"
