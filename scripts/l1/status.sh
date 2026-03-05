#!/bin/bash
# Check status of all Avalanche nodes
#
# Usage: ./scripts/l1/status.sh [aws|gcp|azure]

set -e

CLOUD=${1:-aws}
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get IPs from terraform
cd "$ROOT_DIR/terraform/l1/$CLOUD"

if ! terraform output validator_ips &>/dev/null; then
    echo "No infrastructure found. Run 'make infra' first."
    exit 1
fi

VALIDATOR_IPS=$(terraform output -json validator_ips 2>/dev/null | jq -r '.[]' 2>/dev/null || echo "")
RPC_IPS=$(terraform output -json rpc_ips 2>/dev/null | jq -r '.[]' 2>/dev/null || echo "")

# Load L1 config if exists
L1_ENV="$ROOT_DIR/l1.env"
CHAIN_ID=""
if [ -f "$L1_ENV" ]; then
    source "$L1_ENV"
fi

echo "============================================"
echo "  Avalanche Node Status"
echo "============================================"
echo ""

check_node() {
    local ip=$1
    local name=$2
    local check_rpc=${3:-false}

    # Check if reachable (try port 9650)
    if ! curl -s --connect-timeout 3 "http://$ip:9650/ext/info" &>/dev/null; then
        # Port 9650 not accessible (expected for validators from outside)
        if [ "$check_rpc" = "false" ]; then
            echo -e "$name ($ip): ${YELLOW}9650 NOT EXPOSED${NC} (expected for validators)"
            return 0
        else
            echo -e "$name ($ip): ${RED}OFFLINE${NC}"
            return 1
        fi
    fi

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
    local status="${YELLOW}SYNCING${NC}"
    if [ "$p_boot" = "true" ] && [ "$c_boot" = "true" ] && [ "$x_boot" = "true" ]; then
        status="${GREEN}READY${NC}"
    fi

    # Format chain status
    local p_status="P:$([ "$p_boot" = "true" ] && echo -e "${GREEN}OK${NC}" || echo -e "${YELLOW}...${NC}")"
    local c_status="C:$([ "$c_boot" = "true" ] && echo -e "${GREEN}OK${NC}" || echo -e "${YELLOW}...${NC}")"
    local x_status="X:$([ "$x_boot" = "true" ] && echo -e "${GREEN}OK${NC}" || echo -e "${YELLOW}...${NC}")"

    echo -e "$name ($ip)"
    echo -e "  Status:  $status  [$p_status $c_status $x_status]"
    echo "  NodeID:  $node_id"

    # Check L1 chain if configured
    if [ -n "$CHAIN_ID" ]; then
        local l1_rpc="http://$ip:9650/ext/bc/$CHAIN_ID/rpc"
        local l1_block=$(curl -s -X POST --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
            -H 'content-type:application/json' "$l1_rpc" 2>/dev/null | jq -r '.result // "error"')
        if [ "$l1_block" != "error" ] && [ "$l1_block" != "null" ]; then
            local block_dec=$((l1_block))
            echo -e "  L1:      ${GREEN}ACTIVE${NC} (block $block_dec)"
        else
            echo -e "  L1:      ${YELLOW}NOT READY${NC}"
        fi
    fi

    echo ""
}

# Check validators
if [ -n "$VALIDATOR_IPS" ]; then
    echo "--- Validators ---"
    i=1
    for ip in $VALIDATOR_IPS; do
        check_node "$ip" "validator-$i" "false"
        ((i++))
    done
fi

# Check RPC nodes
if [ -n "$RPC_IPS" ]; then
    echo "--- RPC Nodes ---"
    i=1
    for ip in $RPC_IPS; do
        check_node "$ip" "rpc-$i" "true"
        ((i++))
    done
fi

# Summary
echo "============================================"

# Check if primary network is ready (using RPC nodes if available, otherwise try validators)
all_ready=true
check_ips="${RPC_IPS:-$VALIDATOR_IPS}"
for ip in $check_ips; do
    p_boot=$(curl -s --connect-timeout 3 -X POST --data '{"jsonrpc":"2.0","id":1,"method":"info.isBootstrapped","params":{"chain":"P"}}' \
        -H 'content-type:application/json' "http://$ip:9650/ext/info" 2>/dev/null | jq -r '.result.isBootstrapped // false')
    if [ "$p_boot" = "true" ]; then
        break  # At least one node is ready
    fi
    all_ready=false
done

if [ "$all_ready" = "true" ] || [ "$p_boot" = "true" ]; then
    echo -e "  Primary Network: ${GREEN}READY${NC}"
else
    echo -e "  Primary Network: ${YELLOW}SYNCING${NC}"
fi

# Check L1 status
if [ -n "$CHAIN_ID" ]; then
    l1_working=false
    for ip in $check_ips; do
        l1_rpc="http://$ip:9650/ext/bc/$CHAIN_ID/rpc"
        l1_block=$(curl -s --connect-timeout 3 -X POST --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
            -H 'content-type:application/json' "$l1_rpc" 2>/dev/null | jq -r '.result // "error"')
        if [ "$l1_block" != "error" ] && [ "$l1_block" != "null" ]; then
            l1_working=true
            break
        fi
    done

    if [ "$l1_working" = "true" ]; then
        echo -e "  L1 Chain:        ${GREEN}OPERATIONAL${NC}"
        echo ""
        echo "  RPC Endpoint:"
        for ip in $check_ips; do
            echo "    http://$ip:9650/ext/bc/$CHAIN_ID/rpc"
            break  # Just show first one
        done
    else
        echo -e "  L1 Chain:        ${YELLOW}NOT READY${NC}"
    fi
fi

echo "============================================"
