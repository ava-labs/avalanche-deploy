#!/bin/bash
# Generate Safe v1.4.1 genesis entries with correct runtime bytecode
# This script fetches the correct bytecode from Ethereum mainnet and outputs
# JSON that can be merged into your genesis alloc section

set -e

MAINNET_RPC="${MAINNET_RPC:-https://ethereum.publicnode.com}"
OUTPUT_FILE="${1:-safe-genesis-alloc.json}"

echo "Fetching Safe v1.4.1 runtime bytecode from Ethereum mainnet..."

# Safe v1.4.1 canonical addresses
SAFE_PROXY_FACTORY="0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67"
SAFE_L2="0x29fcB43b46531BcA003ddC8FCB67FFE91900C762"
SAFE="0x41675C099F32341bf84BFc5382aF534df5C7461a"  # Non-L2 Safe (optional)
MULTI_SEND="0x38869bf66a61cF6bDB996A6aE40D5853Fd43B526"
MULTI_SEND_CALL_ONLY="0x9641d764fc13c8B624c04430C7356C1C7C8102e2"
FALLBACK_HANDLER="0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99"
CREATE_CALL="0x9b35Af71d77eaf8d7e40252370304687390A1A52"
SIGN_MESSAGE_LIB="0xd53cd0aB83D845Ac265BE939c57F53AD838012c9"
SIMULATE_TX_ACCESSOR="0x3d4BA2E0884aa488718476ca2FB8Efc291A46199"
SINGLETON_FACTORY="0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7"

# Check for cast
if ! command -v cast &> /dev/null; then
    echo "Error: 'cast' (from foundry) is required but not installed."
    echo "Install foundry: curl -L https://foundry.paradigm.xyz | bash && foundryup"
    exit 1
fi

fetch_code() {
    local addr=$1
    local name=$2
    local code
    code=$(cast code "$addr" --rpc-url "$MAINNET_RPC" 2>&1)
    if [[ ! "$code" == 0x* ]] || [[ ${#code} -lt 100 ]]; then
        echo "Error fetching $name at $addr: $code" >&2
        exit 1
    fi
    echo "$code"
}

echo "  Fetching SafeProxyFactory..."
FACTORY_CODE=$(fetch_code "$SAFE_PROXY_FACTORY" "SafeProxyFactory")

echo "  Fetching SafeL2..."
SAFE_L2_CODE=$(fetch_code "$SAFE_L2" "SafeL2")

echo "  Fetching MultiSend..."
MULTI_SEND_CODE=$(fetch_code "$MULTI_SEND" "MultiSend")

echo "  Fetching MultiSendCallOnly..."
MULTI_SEND_CO_CODE=$(fetch_code "$MULTI_SEND_CALL_ONLY" "MultiSendCallOnly")

echo "  Fetching CompatibilityFallbackHandler..."
FALLBACK_CODE=$(fetch_code "$FALLBACK_HANDLER" "FallbackHandler")

echo "  Fetching CreateCall..."
CREATE_CALL_CODE=$(fetch_code "$CREATE_CALL" "CreateCall")

echo "  Fetching SignMessageLib..."
SIGN_MSG_CODE=$(fetch_code "$SIGN_MESSAGE_LIB" "SignMessageLib")

echo "  Fetching SimulateTxAccessor..."
SIMULATE_CODE=$(fetch_code "$SIMULATE_TX_ACCESSOR" "SimulateTxAccessor")

echo "  Fetching SingletonFactory..."
SINGLETON_CODE=$(fetch_code "$SINGLETON_FACTORY" "SingletonFactory")

echo ""
echo "Generating genesis alloc entries..."

# Convert addresses to lowercase without 0x prefix for genesis format
to_genesis_addr() {
    echo "$1" | sed 's/^0x//' | tr '[:upper:]' '[:lower:]'
}

# Generate JSON output
cat > "$OUTPUT_FILE" << EOF
{
  "$(to_genesis_addr $SAFE_PROXY_FACTORY)": {
    "balance": "0x0",
    "code": "$FACTORY_CODE"
  },
  "$(to_genesis_addr $SAFE_L2)": {
    "balance": "0x0",
    "code": "$SAFE_L2_CODE"
  },
  "$(to_genesis_addr $MULTI_SEND)": {
    "balance": "0x0",
    "code": "$MULTI_SEND_CODE"
  },
  "$(to_genesis_addr $MULTI_SEND_CALL_ONLY)": {
    "balance": "0x0",
    "code": "$MULTI_SEND_CO_CODE"
  },
  "$(to_genesis_addr $FALLBACK_HANDLER)": {
    "balance": "0x0",
    "code": "$FALLBACK_CODE"
  },
  "$(to_genesis_addr $CREATE_CALL)": {
    "balance": "0x0",
    "code": "$CREATE_CALL_CODE"
  },
  "$(to_genesis_addr $SIGN_MESSAGE_LIB)": {
    "balance": "0x0",
    "code": "$SIGN_MSG_CODE"
  },
  "$(to_genesis_addr $SIMULATE_TX_ACCESSOR)": {
    "balance": "0x0",
    "code": "$SIMULATE_CODE"
  },
  "$(to_genesis_addr $SINGLETON_FACTORY)": {
    "balance": "0x0",
    "code": "$SINGLETON_CODE"
  }
}
EOF

echo ""
echo "Safe genesis entries written to: $OUTPUT_FILE"
echo ""
echo "To add these to your genesis, merge the alloc entries:"
echo "  jq -s '.[0] * {alloc: (.[0].alloc + .[1])}' configs/l1/genesis/genesis.json $OUTPUT_FILE > configs/l1/genesis/genesis.new.json"
echo ""
echo "Contract addresses (use these in Safe infrastructure config):"
echo "  SafeProxyFactory:    $SAFE_PROXY_FACTORY"
echo "  SafeL2:              $SAFE_L2"
echo "  MultiSend:           $MULTI_SEND"
echo "  MultiSendCallOnly:   $MULTI_SEND_CALL_ONLY"
echo "  FallbackHandler:     $FALLBACK_HANDLER"
echo "  CreateCall:          $CREATE_CALL"
echo "  SignMessageLib:      $SIGN_MESSAGE_LIB"
echo "  SimulateTxAccessor:  $SIMULATE_TX_ACCESSOR"
echo "  SingletonFactory:    $SINGLETON_FACTORY"
