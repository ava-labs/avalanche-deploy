#!/bin/bash
# Create an Avalanche L1 from Kubernetes validators
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Defaults
NETWORK="fuji"
CHAIN_NAME="mychain"
RELEASE="validators"
OUTPUT="l1.env"

# Parse args
while [[ $# -gt 0 ]]; do
    case $1 in
        --network=*) NETWORK="${1#*=}"; shift ;;
        --chain-name=*) CHAIN_NAME="${1#*=}"; shift ;;
        --release=*) RELEASE="${1#*=}"; shift ;;
        --output=*) OUTPUT="${1#*=}"; shift ;;
        --genesis=*) GENESIS="${1#*=}"; shift ;;
        -h|--help)
            echo "Usage: $0 [options]"
            echo "  --network=fuji|mainnet  Network (default: fuji)"
            echo "  --chain-name=NAME       Chain name (default: mychain)"
            echo "  --release=NAME          Helm release name (default: validators)"
            echo "  --genesis=FILE          Genesis file (default: auto-find)"
            echo "  --output=FILE           Output file (default: l1.env)"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Check private key
if [ -z "$AVALANCHE_PRIVATE_KEY" ]; then
    echo "Error: AVALANCHE_PRIVATE_KEY not set"
    echo "Export your funded P-Chain private key:"
    echo "  export AVALANCHE_PRIVATE_KEY=\"0x...\""
    exit 1
fi

# Build create-l1 if needed
CREATE_L1="$ROOT_DIR/tools/create-l1/create-l1"
if [ ! -f "$CREATE_L1" ]; then
    echo "Building create-l1 tool..."
    (cd "$ROOT_DIR/tools/create-l1" && go build -o create-l1 .)
fi

# Get validator pod IPs
echo "Getting validator pod IPs..."
PODS=$(kubectl get pods -l app.kubernetes.io/instance=$RELEASE -o jsonpath='{.items[*].metadata.name}')

if [ -z "$PODS" ]; then
    echo "No pods found for release: $RELEASE"
    exit 1
fi

# For kind/local, we need to use pod IPs
# For cloud, we'd use service IPs or node IPs
VALIDATOR_IPS=""
for pod in $PODS; do
    IP=$(kubectl get pod $pod -o jsonpath='{.status.podIP}')
    if [ -n "$VALIDATOR_IPS" ]; then
        VALIDATOR_IPS="$VALIDATOR_IPS,$IP"
    else
        VALIDATOR_IPS="$IP"
    fi
done

echo "Validators: $VALIDATOR_IPS"

# Find genesis file
if [ -z "$GENESIS" ]; then
    if [ -f "$ROOT_DIR/configs/l1/genesis/genesis.json" ]; then
        GENESIS="$ROOT_DIR/configs/l1/genesis/genesis.json"
    elif [ -f "$ROOT_DIR/genesis.json" ]; then
        # Backward-compatible fallback for older checkouts.
        GENESIS="$ROOT_DIR/genesis.json"
    else
        echo "Error: No genesis file found. Create configs/l1/genesis/genesis.json."
        exit 1
    fi
fi

echo "Genesis: $GENESIS"
echo "Network: $NETWORK"
echo "Chain Name: $CHAIN_NAME"
echo ""

# Port-forward to first validator for RPC access
echo "Setting up port-forward to validators..."
kubectl port-forward pod/${PODS%% *} 19650:9650 &
PF_PID=$!
sleep 3

# Trap to cleanup port-forward
trap "kill $PF_PID 2>/dev/null" EXIT

# Create L1
echo "Creating L1..."
$CREATE_L1 \
    --network=$NETWORK \
    --validators=$VALIDATOR_IPS \
    --chain-name=$CHAIN_NAME \
    --genesis=$GENESIS \
    --output=$OUTPUT

echo ""
echo "L1 created! Config saved to: $OUTPUT"
echo ""
echo "Next: Run ./scripts/configure-l1.sh to update validators"
