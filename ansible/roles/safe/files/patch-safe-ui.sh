#!/bin/bash
# Patch Safe UI to support custom chain ID
# This script adds the chain to the networkAddresses in the bundled JavaScript
# so that @safe-global/safe-deployments recognizes the chain.

set -e

CHAIN_ID="$1"
SAFE_SINGLETON="$2"
PROXY_FACTORY="$3"
MULTI_SEND="$4"
MULTI_SEND_CALL_ONLY="$5"
FALLBACK_HANDLER="$6"
CREATE_CALL="$7"
SIGN_MESSAGE_LIB="$8"
SIMULATE_TX_ACCESSOR="$9"

# Input validation
if [ -z "$CHAIN_ID" ]; then
    echo "Usage: $0 <chain_id> <safe_singleton> <proxy_factory> <multi_send> <multi_send_call_only> <fallback_handler> <create_call> <sign_message_lib> <simulate_tx_accessor>"
    exit 1
fi

# Validate chain ID is numeric
if ! [[ "$CHAIN_ID" =~ ^[0-9]+$ ]]; then
    echo "Error: Chain ID must be numeric, got: $CHAIN_ID"
    exit 1
fi

# Validate Ethereum addresses (0x + 40 hex chars)
validate_address() {
    local name=$1
    local addr=$2
    if ! [[ "$addr" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
        echo "Error: Invalid Ethereum address for $name: $addr"
        exit 1
    fi
}

validate_address "SAFE_SINGLETON" "$SAFE_SINGLETON"
validate_address "PROXY_FACTORY" "$PROXY_FACTORY"
validate_address "MULTI_SEND" "$MULTI_SEND"
validate_address "MULTI_SEND_CALL_ONLY" "$MULTI_SEND_CALL_ONLY"
validate_address "FALLBACK_HANDLER" "$FALLBACK_HANDLER"
validate_address "CREATE_CALL" "$CREATE_CALL"
validate_address "SIGN_MESSAGE_LIB" "$SIGN_MESSAGE_LIB"
validate_address "SIMULATE_TX_ACCESSOR" "$SIMULATE_TX_ACCESSOR"

echo "Input validation passed."

# Canonical addresses from @safe-global/safe-deployments v1.4.1
# We add our chain to these contracts' networkAddresses
OLD_SAFE="0x41675C099F32341bf84BFc5382aF534df5C7461a"       # Non-L2 Safe
OLD_SAFE_L2="0x29fcB43b46531BcA003ddC8FCB67FFE91900C762"    # L2 Safe
OLD_FACTORY="0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67"
OLD_MULTISEND="0x38869bf66a61cF6bDB996A6aE40D5853Fd43B526"
OLD_MULTISEND_CO="0x9641d764fc13c8B624c04430C7356C1C7C8102e2"
OLD_FALLBACK="0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99"
OLD_CREATE="0x9b35Af71d77eaf8d7e40252370304687390A1A52"
OLD_SIGNMSG="0xd53cd0aB83D845Ac265BE939c57F53AD838012c9"
OLD_SIMULATE="0x3d4BA2E0884aa488718476ca2FB8Efc291A46199"

# Find the main app JS file
APP_JS=$(find /tmp/safe-ui-patched/_next -name "_app-*.js" 2>/dev/null | head -1)

if [ -z "$APP_JS" ]; then
    # Try alternate locations for different Safe UI versions
    APP_JS=$(find /tmp/safe-ui-patched/_next -name "*.js" -exec grep -l "networkAddresses" {} \; 2>/dev/null | head -1)
fi

if [ -z "$APP_JS" ]; then
    echo "Error: Could not find JavaScript file containing networkAddresses"
    echo "Contents of /tmp/safe-ui-patched/_next:"
    find /tmp/safe-ui-patched/_next -type f -name "*.js" 2>/dev/null | head -20
    exit 1
fi

echo "Patching $APP_JS for chain $CHAIN_ID..."

# Create backup
cp "$APP_JS" "${APP_JS}.bak"

# Function to add chain entry to networkAddresses
# Uses multiple patterns to handle different JS bundle formats
add_chain_entry() {
    local old_addr=$1
    local new_addr=$2
    local contract_name=$3

    # Pattern 1: "networkAddresses":{"1":"<addr>"
    if grep -q "\"networkAddresses\":{\"1\":\"${old_addr}\"" "$APP_JS"; then
        sed -i.tmp "s|\"networkAddresses\":{\"1\":\"${old_addr}\"|\"networkAddresses\":{\"1\":\"${old_addr}\",\"${CHAIN_ID}\":\"${new_addr}\"|g" "$APP_JS"
        rm -f "${APP_JS}.tmp"
        echo "  Patched $contract_name (pattern 1)"
        return 0
    fi

    # Pattern 2: networkAddresses:{"1":"<addr>" (no quotes on key)
    if grep -q "networkAddresses:{\"1\":\"${old_addr}\"" "$APP_JS"; then
        sed -i.tmp "s|networkAddresses:{\"1\":\"${old_addr}\"|networkAddresses:{\"1\":\"${old_addr}\",\"${CHAIN_ID}\":\"${new_addr}\"|g" "$APP_JS"
        rm -f "${APP_JS}.tmp"
        echo "  Patched $contract_name (pattern 2)"
        return 0
    fi

    # Pattern 3: "networkAddresses":{...,"11155111":"<addr>" (find any existing chain, add after)
    if grep -q "\"networkAddresses\":{[^}]*\"[0-9]*\":\"${old_addr}\"" "$APP_JS"; then
        # Add our chain after any existing entry for this address
        sed -i.tmp "s|\":\"${old_addr}\"|\":\"${old_addr}\",\"${CHAIN_ID}\":\"${new_addr}\"|g" "$APP_JS"
        rm -f "${APP_JS}.tmp"
        echo "  Patched $contract_name (pattern 3)"
        return 0
    fi

    echo "  Warning: Could not find pattern for $contract_name ($old_addr)"
    return 1
}

# Add chain entries for each contract
PATCH_COUNT=0
add_chain_entry "$OLD_SAFE" "$SAFE_SINGLETON" "Safe (L1)" && ((PATCH_COUNT++)) || true
add_chain_entry "$OLD_SAFE_L2" "$SAFE_SINGLETON" "SafeL2" && ((PATCH_COUNT++)) || true
add_chain_entry "$OLD_FACTORY" "$PROXY_FACTORY" "ProxyFactory" && ((PATCH_COUNT++)) || true
add_chain_entry "$OLD_MULTISEND" "$MULTI_SEND" "MultiSend" && ((PATCH_COUNT++)) || true
add_chain_entry "$OLD_MULTISEND_CO" "$MULTI_SEND_CALL_ONLY" "MultiSendCallOnly" && ((PATCH_COUNT++)) || true
add_chain_entry "$OLD_FALLBACK" "$FALLBACK_HANDLER" "FallbackHandler" && ((PATCH_COUNT++)) || true
add_chain_entry "$OLD_CREATE" "$CREATE_CALL" "CreateCall" && ((PATCH_COUNT++)) || true
add_chain_entry "$OLD_SIGNMSG" "$SIGN_MESSAGE_LIB" "SignMessageLib" && ((PATCH_COUNT++)) || true
add_chain_entry "$OLD_SIMULATE" "$SIMULATE_TX_ACCESSOR" "SimulateTxAccessor" && ((PATCH_COUNT++)) || true

# Verify patches
FINAL_COUNT=$(grep -o "\"${CHAIN_ID}\":\"0x" "$APP_JS" 2>/dev/null | wc -l | tr -d ' ')
echo ""
echo "Patch summary:"
echo "  Successful patches: $PATCH_COUNT"
echo "  Chain $CHAIN_ID entries in file: $FINAL_COUNT"

if [ "$FINAL_COUNT" -lt 5 ]; then
    echo ""
    echo "WARNING: Expected at least 5 entries, got $FINAL_COUNT"
    echo "The Safe UI may not work correctly for chain $CHAIN_ID"
    echo ""
    echo "Restoring backup and exiting with error..."
    mv "${APP_JS}.bak" "$APP_JS"
    exit 1
fi

# Remove backup on success
rm -f "${APP_JS}.bak"

echo ""
echo "Contract patches complete."

# Patch Gateway URL in all JS files
# Replace the default Safe Global gateway with our local /cgw path
echo ""
echo "Patching Gateway URL..."

DEFAULT_GATEWAY="https://safe-client.safe.global"
LOCAL_GATEWAY="/cgw"

# Find all JS files and replace the gateway URL
JS_FILES=$(find /tmp/safe-ui-patched -name "*.js" -type f 2>/dev/null)
GATEWAY_PATCHED=0

for js_file in $JS_FILES; do
    if grep -q "$DEFAULT_GATEWAY" "$js_file" 2>/dev/null; then
        sed -i.tmp "s|$DEFAULT_GATEWAY|$LOCAL_GATEWAY|g" "$js_file"
        rm -f "${js_file}.tmp"
        GATEWAY_PATCHED=$((GATEWAY_PATCHED + 1))
    fi
done

echo "  Patched gateway URL in $GATEWAY_PATCHED files"

# Verify gateway patch
REMAINING=$(grep -r "$DEFAULT_GATEWAY" /tmp/safe-ui-patched 2>/dev/null | wc -l | tr -d ' ')
if [ "$REMAINING" -gt 0 ]; then
    echo "  Warning: $REMAINING references to default gateway remain"
fi

echo ""
echo "Patch complete - Safe UI now supports chain $CHAIN_ID with local gateway"
