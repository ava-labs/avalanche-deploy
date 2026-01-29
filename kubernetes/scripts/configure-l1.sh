#!/bin/bash
# Configure Kubernetes validators to track an L1 subnet
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
K8S_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(dirname "$K8S_DIR")"

RELEASE=${1:-validators}
L1_ENV=${2:-l1.env}

# Load L1 config
if [ ! -f "$L1_ENV" ]; then
    echo "Error: $L1_ENV not found"
    echo "Run ./scripts/create-l1.sh first"
    exit 1
fi

source "$L1_ENV"

if [ -z "$SUBNET_ID" ] || [ -z "$CHAIN_ID" ]; then
    echo "Error: SUBNET_ID or CHAIN_ID not found in $L1_ENV"
    exit 1
fi

echo "Configuring validators for L1..."
echo "  Subnet ID: $SUBNET_ID"
echo "  Chain ID:  $CHAIN_ID"
echo ""

# Get validator pods
PODS=$(kubectl get pods -l app.kubernetes.io/instance=$RELEASE -o jsonpath='{.items[*].metadata.name}')

if [ -z "$PODS" ]; then
    echo "No pods found for release: $RELEASE"
    exit 1
fi

# Get NodeIDs for bootstrap config
echo "Gathering NodeIDs..."
BOOTSTRAP_IDS=""
BOOTSTRAP_IPS=""

for pod in $PODS; do
    NODE_ID=$(kubectl exec $pod -- curl -s localhost:9650/ext/info \
        -X POST -H 'content-type:application/json' \
        -d '{"jsonrpc":"2.0","id":1,"method":"info.getNodeID"}' | \
        grep -o '"nodeID":"[^"]*"' | cut -d'"' -f4)

    POD_IP=$(kubectl get pod $pod -o jsonpath='{.status.podIP}')

    echo "  $pod: $NODE_ID ($POD_IP)"

    if [ -n "$BOOTSTRAP_IDS" ]; then
        BOOTSTRAP_IDS="$BOOTSTRAP_IDS,$NODE_ID"
        BOOTSTRAP_IPS="$BOOTSTRAP_IPS,$POD_IP:9651"
    else
        BOOTSTRAP_IDS="$NODE_ID"
        BOOTSTRAP_IPS="$POD_IP:9651"
    fi
done

echo ""
echo "Updating validator configs..."

# Create ConfigMap with L1 config
kubectl create configmap l1-config \
    --from-literal=SUBNET_ID=$SUBNET_ID \
    --from-literal=CHAIN_ID=$CHAIN_ID \
    --from-literal=BOOTSTRAP_IDS=$BOOTSTRAP_IDS \
    --from-literal=BOOTSTRAP_IPS=$BOOTSTRAP_IPS \
    --dry-run=client -o yaml | kubectl apply -f -

# Upgrade helm release with subnet tracking
helm upgrade $RELEASE "$K8S_DIR/helm/avalanche-validator" \
    --reuse-values \
    --set config.trackSubnets=$SUBNET_ID \
    --set l1.subnetId=$SUBNET_ID \
    --set l1.chainId=$CHAIN_ID \
    --set l1.bootstrapIds=$BOOTSTRAP_IDS \
    --set l1.bootstrapIps=$BOOTSTRAP_IPS

echo ""
echo "Validators updated! Waiting for pods to restart..."

# Wait for rollout
kubectl rollout status statefulset/${RELEASE}-avalanche-validator --timeout=300s

echo ""
echo "Verifying L1 RPC..."
sleep 10

# Check L1 is accessible
for pod in $PODS; do
    CHAIN_RESPONSE=$(kubectl exec $pod -- curl -s localhost:9650/ext/bc/$CHAIN_ID/rpc \
        -X POST -H 'content-type:application/json' \
        -d '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' 2>/dev/null || echo "error")

    if echo "$CHAIN_RESPONSE" | grep -q "result"; then
        echo "  $pod: L1 ready ✓"
    else
        echo "  $pod: L1 not ready yet"
    fi
done

echo ""
echo "Done! L1 is configured."
echo ""
echo "RPC endpoint (via port-forward):"
echo "  kubectl port-forward svc/${RELEASE}-avalanche-validator 9650:9650"
echo "  curl localhost:9650/ext/bc/$CHAIN_ID/rpc -X POST -H 'content-type:application/json' -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_chainId\",\"params\":[]}'"
