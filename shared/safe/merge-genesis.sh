#!/bin/bash
# Merge Safe v1.4.1 contracts into genesis.json
# Usage: ./merge-genesis.sh [genesis.json path]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENESIS_FILE="${1:-$SCRIPT_DIR/../../genesis.json}"
CONTRACTS_FILE="$SCRIPT_DIR/genesis-contracts.json"

if [ ! -f "$GENESIS_FILE" ]; then
    echo "Error: Genesis file not found: $GENESIS_FILE"
    exit 1
fi

if [ ! -f "$CONTRACTS_FILE" ]; then
    echo "Error: Contracts file not found: $CONTRACTS_FILE"
    exit 1
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed"
    exit 1
fi

echo "Merging Safe v1.4.1 contracts into $GENESIS_FILE..."

# Extract contracts and merge into genesis alloc
TEMP_FILE=$(mktemp)
jq -s '
  .[0] as $genesis |
  .[1].contracts as $contracts |
  $genesis | .alloc += ($contracts | to_entries | map({
    key: .key,
    value: {
      balance: .value.balance,
      code: .value.code
    }
  }) | from_entries)
' "$GENESIS_FILE" "$CONTRACTS_FILE" > "$TEMP_FILE"

# Validate the output
if ! jq empty "$TEMP_FILE" 2>/dev/null; then
    echo "Error: Failed to create valid JSON"
    rm -f "$TEMP_FILE"
    exit 1
fi

# Replace original file
mv "$TEMP_FILE" "$GENESIS_FILE"

echo "Successfully merged the following Safe contracts:"
jq -r '.contracts | to_entries[] | "  \(.key): \(.value.name)"' "$CONTRACTS_FILE"
echo ""
echo "Genesis file updated: $GENESIS_FILE"
