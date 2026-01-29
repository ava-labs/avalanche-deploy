#!/bin/bash
# Wait for all nodes to finish syncing
#
# Usage: ./scripts/wait-for-sync.sh [aws|gcp|azure]

set -e

CLOUD=${1:-aws}
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR/terraform/$CLOUD"

if ! terraform output validator_ips &>/dev/null; then
    echo "No infrastructure found. Run 'make infra' first."
    exit 1
fi

IPS=$(terraform output -json validator_ips | jq -r '.[]')
FIRST_IP=$(echo "$IPS" | head -1)

echo "Waiting for nodes to sync with Fuji..."
echo "This typically takes 10-30 minutes."
echo ""
echo "Press Ctrl+C to stop waiting (nodes will continue syncing)"
echo ""

check_bootstrapped() {
    local ip=$1
    local chain=$2
    curl -s -X POST --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"info.isBootstrapped\",\"params\":{\"chain\":\"$chain\"}}" \
        -H 'content-type:application/json' "http://$ip:9650/ext/info" 2>/dev/null | jq -r '.result.isBootstrapped // false'
}

spin='-\|/'
i=0
while true; do
    # Check P-chain on first node (if first is synced, others likely are too)
    p_boot=$(check_bootstrapped "$FIRST_IP" "P")
    c_boot=$(check_bootstrapped "$FIRST_IP" "C")
    x_boot=$(check_bootstrapped "$FIRST_IP" "X")

    # Show spinner
    i=$(( (i+1) % 4 ))
    printf "\r${spin:$i:1} P-chain: %-5s  C-chain: %-5s  X-chain: %-5s" \
        "$([ "$p_boot" = "true" ] && echo "OK" || echo "...")" \
        "$([ "$c_boot" = "true" ] && echo "OK" || echo "...")" \
        "$([ "$x_boot" = "true" ] && echo "OK" || echo "...")"

    # Check if all done
    if [ "$p_boot" = "true" ] && [ "$c_boot" = "true" ] && [ "$x_boot" = "true" ]; then
        echo ""
        echo ""
        echo "All chains bootstrapped!"
        echo ""
        echo "Next step:"
        echo "  make create-l1"
        echo "  export AVALANCHE_PRIVATE_KEY='PrivateKey-...'"
        echo "  cd tools/create-l1 && ./create-l1 --network=fuji --validators=\$VALIDATORS"
        exit 0
    fi

    sleep 5
done
