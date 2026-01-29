#!/bin/bash
# Check status of Avalanche nodes in Kubernetes
set -e

RELEASE=${1:-validators}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "============================================"
echo "  Avalanche Kubernetes Status"
echo "============================================"
echo ""

# Get pods
PODS=$(kubectl get pods -l app.kubernetes.io/instance=$RELEASE -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

if [ -z "$PODS" ]; then
    echo -e "${RED}No pods found for release: $RELEASE${NC}"
    echo "Deploy with: helm install $RELEASE ./helm/avalanche-validator"
    exit 1
fi

# Check L1 config
L1_CONFIG=$(kubectl get configmap l1-config -o jsonpath='{.data.CHAIN_ID}' 2>/dev/null || echo "")

echo "--- Pods ---"
for pod in $PODS; do
    # Get pod status
    POD_STATUS=$(kubectl get pod $pod -o jsonpath='{.status.phase}')
    POD_IP=$(kubectl get pod $pod -o jsonpath='{.status.podIP}')

    if [ "$POD_STATUS" != "Running" ]; then
        echo -e "$pod: ${RED}$POD_STATUS${NC}"
        continue
    fi

    # Check P-Chain bootstrap
    P_BOOT=$(kubectl exec $pod -- curl -s localhost:9650/ext/info \
        -X POST -H 'content-type:application/json' \
        -d '{"jsonrpc":"2.0","id":1,"method":"info.isBootstrapped","params":{"chain":"P"}}' \
        2>/dev/null | grep -o '"isBootstrapped":[^,}]*' | cut -d: -f2)

    # Get NodeID
    NODE_ID=$(kubectl exec $pod -- curl -s localhost:9650/ext/info \
        -X POST -H 'content-type:application/json' \
        -d '{"jsonrpc":"2.0","id":1,"method":"info.getNodeID"}' \
        2>/dev/null | grep -o '"nodeID":"[^"]*"' | cut -d'"' -f4)

    # Format status
    if [ "$P_BOOT" = "true" ]; then
        STATUS="${GREEN}READY${NC}"
        P_STATUS="${GREEN}OK${NC}"
    else
        STATUS="${YELLOW}SYNCING${NC}"
        P_STATUS="${YELLOW}...${NC}"
    fi

    echo -e "$pod ($POD_IP)"
    echo -e "  Status: $STATUS  [P:$P_STATUS]"
    echo "  NodeID: $NODE_ID"

    # Check L1 if configured
    if [ -n "$L1_CONFIG" ]; then
        L1_BLOCK=$(kubectl exec $pod -- curl -s localhost:9650/ext/bc/$L1_CONFIG/rpc \
            -X POST -H 'content-type:application/json' \
            -d '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
            2>/dev/null | grep -o '"result":"[^"]*"' | cut -d'"' -f4)

        if [ -n "$L1_BLOCK" ] && [ "$L1_BLOCK" != "null" ]; then
            BLOCK_DEC=$((L1_BLOCK))
            echo -e "  L1:     ${GREEN}ACTIVE${NC} (block $BLOCK_DEC)"
        else
            echo -e "  L1:     ${YELLOW}NOT READY${NC}"
        fi
    fi
    echo ""
done

echo "============================================"

# Summary
if [ -n "$L1_CONFIG" ]; then
    SUBNET_ID=$(kubectl get configmap l1-config -o jsonpath='{.data.SUBNET_ID}' 2>/dev/null)
    echo "Subnet ID: $SUBNET_ID"
    echo "Chain ID:  $L1_CONFIG"
    echo ""
    echo "RPC (port-forward):"
    echo "  kubectl port-forward svc/${RELEASE}-avalanche-validator 9650:9650"
    echo "  http://localhost:9650/ext/bc/$L1_CONFIG/rpc"
else
    echo "L1 not configured yet."
    echo "Run ./scripts/create-l1.sh after nodes sync."
fi
echo "============================================"
