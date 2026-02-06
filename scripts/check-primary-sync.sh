#!/bin/bash
# Check Primary Network sync status (P/X/C chains)
#
# Usage:
#   ./check-primary-sync.sh [node-ip]
#   ./check-primary-sync.sh                    # Check all primary validators
#   ./check-primary-sync.sh 10.0.1.50          # Check specific node
#
# Returns 0 when all chains are bootstrapped, 1 otherwise.

set -euo pipefail

NODE_IP="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLOUD="${CLOUD:-aws}"
INVENTORY="${INVENTORY:-$REPO_ROOT/ansible/inventory/${CLOUD}_hosts}"

check_chain() {
    local ip=$1
    local chain=$2
    local result
    local bootstrapped

    result=$(curl -s --connect-timeout 5 "http://$ip:9650/ext/info" \
        -X POST \
        -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"info.isBootstrapped\",\"params\":{\"chain\":\"$chain\"}}" \
        2>/dev/null || true)

    if [ -z "$result" ]; then
        echo "UNREACHABLE"
        return 1
    fi

    bootstrapped=$(printf '%s' "$result" | jq -r '.result.isBootstrapped // false' 2>/dev/null || echo "false")
    if [ "$bootstrapped" = "true" ]; then
        echo "SYNCED"
        return 0
    else
        echo "SYNCING"
        return 1
    fi
}

check_node() {
    local ip=$1
    local name=${2:-$ip}

    echo "=== $name ($ip) ==="

    local all_synced=true
    local status

    for chain in P X C; do
        status="$(check_chain "$ip" "$chain" || true)"
        printf "  %s-Chain: %s\n" "$chain" "$status"
        if [ "$status" != "SYNCED" ]; then
            all_synced=false
        fi
    done

    if [ "$all_synced" = "true" ]; then
        echo "  Status: FULLY SYNCED"
        return 0
    else
        echo "  Status: SYNCING"
        return 1
    fi
}

if [ -n "$NODE_IP" ]; then
    # Check single node
    check_node "$NODE_IP"
    exit $?
fi

# Check all primary validators from inventory
if [ ! -f "$INVENTORY" ]; then
    echo "Error: Inventory not found at $INVENTORY"
    echo "Run 'make infra CLOUD=$CLOUD' first to create infrastructure."
    exit 1
fi

# Parse inventory for primary validators
ALL_SYNCED=true
FOUND_VALIDATORS=false

while IFS= read -r line; do
    if [[ "$line" =~ ^primary-validator ]]; then
        FOUND_VALIDATORS=true
        name=$(echo "$line" | awk '{print $1}')
        ip=$(echo "$line" | awk '{for (i=1; i<=NF; i++) if ($i ~ /^ansible_host=/) {sub(/^ansible_host=/, "", $i); print $i; break}}')

        if [ -n "$ip" ]; then
            echo ""
            if ! check_node "$ip" "$name"; then
                ALL_SYNCED=false
            fi
        fi
    fi
done < "$INVENTORY"

if [ "$FOUND_VALIDATORS" = "false" ]; then
    echo "No primary validators found in inventory."
    echo "Ensure primary_validator_count > 0 in Terraform."
    exit 1
fi

echo ""
echo "==============================="
if [ "$ALL_SYNCED" = "true" ]; then
    echo "All Primary Network validators are synced!"
    exit 0
else
    echo "Some validators are still syncing..."
    exit 1
fi
