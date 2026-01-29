#!/bin/bash
# Wait for Avalanche nodes to sync P-Chain
set -e

RELEASE=${1:-validators}
TIMEOUT=${2:-1800}  # 30 minutes default

echo "Waiting for P-Chain sync on $RELEASE pods..."

# Get pod names
PODS=$(kubectl get pods -l app.kubernetes.io/instance=$RELEASE -o jsonpath='{.items[*].metadata.name}')

if [ -z "$PODS" ]; then
    echo "No pods found for release: $RELEASE"
    echo "Deploy first: helm install $RELEASE ./helm/avalanche-validator"
    exit 1
fi

START_TIME=$(date +%s)

check_bootstrap() {
    local pod=$1
    kubectl exec $pod -- curl -s localhost:9650/ext/info \
        -X POST -H 'content-type:application/json' \
        -d '{"jsonrpc":"2.0","id":1,"method":"info.isBootstrapped","params":{"chain":"P"}}' \
        2>/dev/null | grep -q '"isBootstrapped":true'
}

while true; do
    ALL_SYNCED=true

    for pod in $PODS; do
        if check_bootstrap $pod; then
            echo "  $pod: P-Chain synced ✓"
        else
            echo "  $pod: syncing..."
            ALL_SYNCED=false
        fi
    done

    if [ "$ALL_SYNCED" = true ]; then
        echo ""
        echo "All nodes synced!"
        break
    fi

    # Check timeout
    ELAPSED=$(($(date +%s) - START_TIME))
    if [ $ELAPSED -gt $TIMEOUT ]; then
        echo "Timeout waiting for sync after ${TIMEOUT}s"
        exit 1
    fi

    echo "  Waiting... (${ELAPSED}s elapsed)"
    sleep 10
done
