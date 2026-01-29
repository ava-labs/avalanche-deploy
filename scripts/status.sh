#!/bin/bash
# Check status of all Avalanche nodes
#
# Usage: ./scripts/status.sh [aws|gcp|azure]

set -e

CLOUD=${1:-aws}
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Get IPs from terraform
cd "$ROOT_DIR/terraform/$CLOUD"

if ! terraform output validator_ips &>/dev/null; then
    echo "No infrastructure found. Run 'make infra' first."
    exit 1
fi

IPS=$(terraform output -json validator_ips | jq -r '.[]')

echo "============================================"
echo "  Avalanche Node Status"
echo "============================================"
echo ""

check_node() {
    local ip=$1
    local name=$2

    # Check if reachable
    if ! curl -s --connect-timeout 2 "http://$ip:9650/ext/health" &>/dev/null; then
        echo "$name ($ip): OFFLINE"
        return
    fi

    # Get health
    local health=$(curl -s "http://$ip:9650/ext/health" 2>/dev/null)
    local healthy=$(echo "$health" | jq -r '.healthy // false')

    # Get bootstrap status
    local p_boot=$(curl -s -X POST --data '{"jsonrpc":"2.0","id":1,"method":"info.isBootstrapped","params":{"chain":"P"}}' \
        -H 'content-type:application/json' "http://$ip:9650/ext/info" 2>/dev/null | jq -r '.result.isBootstrapped // false')
    local c_boot=$(curl -s -X POST --data '{"jsonrpc":"2.0","id":1,"method":"info.isBootstrapped","params":{"chain":"C"}}' \
        -H 'content-type:application/json' "http://$ip:9650/ext/info" 2>/dev/null | jq -r '.result.isBootstrapped // false')
    local x_boot=$(curl -s -X POST --data '{"jsonrpc":"2.0","id":1,"method":"info.isBootstrapped","params":{"chain":"X"}}' \
        -H 'content-type:application/json' "http://$ip:9650/ext/info" 2>/dev/null | jq -r '.result.isBootstrapped // false')

    # Get NodeID
    local node_id=$(curl -s -X POST --data '{"jsonrpc":"2.0","id":1,"method":"info.getNodeID"}' \
        -H 'content-type:application/json' "http://$ip:9650/ext/info" 2>/dev/null | jq -r '.result.nodeID // "unknown"')

    # Format status
    local status="SYNCING"
    if [ "$p_boot" = "true" ] && [ "$c_boot" = "true" ] && [ "$x_boot" = "true" ]; then
        status="READY"
    fi

    # Format chain status
    local p_status="P:$([ "$p_boot" = "true" ] && echo "OK" || echo "...")"
    local c_status="C:$([ "$c_boot" = "true" ] && echo "OK" || echo "...")"
    local x_status="X:$([ "$x_boot" = "true" ] && echo "OK" || echo "...")"

    echo "$name ($ip)"
    echo "  Status:  $status  [$p_status $c_status $x_status]"
    echo "  NodeID:  $node_id"
    echo ""
}

i=1
for ip in $IPS; do
    check_node "$ip" "validator-$i"
    ((i++))
done

# Check if all ready
all_ready=true
for ip in $IPS; do
    p_boot=$(curl -s -X POST --data '{"jsonrpc":"2.0","id":1,"method":"info.isBootstrapped","params":{"chain":"P"}}' \
        -H 'content-type:application/json' "http://$ip:9650/ext/info" 2>/dev/null | jq -r '.result.isBootstrapped // false')
    if [ "$p_boot" != "true" ]; then
        all_ready=false
        break
    fi
done

echo "============================================"
if [ "$all_ready" = "true" ]; then
    echo "  All nodes READY - proceed with create-l1"
else
    echo "  Nodes still syncing - check again in a few minutes"
fi
echo "============================================"
