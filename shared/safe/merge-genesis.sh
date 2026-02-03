#!/bin/bash
# =============================================================================
# Merge Safe v1.4.1 contracts into genesis.json
#
# EXPERIMENTAL: Safe support is not production-ready.
#
# This script merges pre-deployed Safe contract bytecode into your genesis.json
# file. This allows Safe multisig wallets to work on your L1 without requiring
# contract deployment transactions after chain creation.
#
# Usage:
#   ./merge-genesis.sh <genesis.json>
#   ./merge-genesis.sh                    # defaults to genesis.json
#
# To reset genesis.json to clean state:
#   make reset-genesis
#
# Safe contracts added:
#   - Safe L2 Singleton (0x29fcB43b46531BcA003ddC8FCB67FFE91900C762)
#   - SafeProxyFactory (0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67)
#   - MultiSend (0x38869bf66a61cF6bDB996A6aE40D5853Fd43B526)
#   - MultiSendCallOnly (0x9641d764fc13c8B624c04430C7356C1C7C8102e2)
#   - CompatibilityFallbackHandler (0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99)
#   - CreateCall (0x9b35Af71d77eaf8d7e40252370304687390A1A52)
#   - SignMessageLib (0xd53cd0aB83D845Ac265BE939c57F53AD838012c9)
#   - SimulateTxAccessor (0x3d4BA2E0884aa488718476ca2FB8Efc291A46199)
#
# =============================================================================

set -e

GENESIS_FILE="${1:-genesis.json}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACTS_FILE="$SCRIPT_DIR/genesis-contracts.json"

echo "=============================================="
echo "  EXPERIMENTAL: Safe Multisig Genesis Merge"
echo "=============================================="
echo ""
echo "WARNING: Safe support is experimental and not production-ready."
echo "         Known issues: indexing delays, container restarts, HTTPS."
echo ""

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
    echo "Install with: brew install jq"
    exit 1
fi

# Backup original
cp "$GENESIS_FILE" "${GENESIS_FILE}.bak"
echo "Backed up original to ${GENESIS_FILE}.bak"

# Merge the contracts into alloc
echo "Merging Safe contracts into $GENESIS_FILE..."

# Read existing alloc and merge with Safe contracts
jq -s '.[0].alloc = (.[0].alloc + .[1]) | .[0]' "$GENESIS_FILE" "$CONTRACTS_FILE" > "${GENESIS_FILE}.tmp"
mv "${GENESIS_FILE}.tmp" "$GENESIS_FILE"

echo ""
echo "Safe v1.4.1 contracts added:"
echo "  Safe L2 Singleton:        0x29fcB43b46531BcA003ddC8FCB67FFE91900C762"
echo "  SafeProxyFactory:         0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67"
echo "  MultiSend:                0x38869bf66a61cF6bDB996A6aE40D5853Fd43B526"
echo "  MultiSendCallOnly:        0x9641d764fc13c8B624c04430C7356C1C7C8102e2"
echo "  CompatibilityFallback:    0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99"
echo "  CreateCall:               0x9b35Af71d77eaf8d7e40252370304687390A1A52"
echo "  SignMessageLib:           0xd53cd0aB83D845Ac265BE939c57F53AD838012c9"
echo "  SimulateTxAccessor:       0x3d4BA2E0884aa488718476ca2FB8Efc291A46199"
echo ""
echo "Done! Safe contracts merged into $GENESIS_FILE"
echo ""
echo "To reset genesis.json to clean state: make reset-genesis"
