#!/usr/bin/env bash
# Deploy Safe v1.4.1 contracts via the Singleton Factory (0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7)
# Usage: RPC_URL=http://... PRIVATE_KEY=0x... ./deploy-contracts.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INITCODES_DIR="${SCRIPT_DIR}/initcodes"
SINGLETON_FACTORY="0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7"
SALT="0x0000000000000000000000000000000000000000000000000000000000000000"

: "${RPC_URL:?RPC_URL is required}"
: "${PRIVATE_KEY:=${AVALANCHE_PRIVATE_KEY:-}}"
if [[ -z "${PRIVATE_KEY}" ]]; then
  echo "Error: PRIVATE_KEY or AVALANCHE_PRIVATE_KEY must be set"
  exit 1
fi

# Contract name -> canonical address mapping
declare -A CONTRACTS=(
  ["SafeL2"]="0x29fcB43b46531BcA003ddC8FCB67FFE91900C762"
  ["SafeProxyFactory"]="0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67"
  ["MultiSend"]="0x38869bf66a61cF6bDB996A6aE40D5853Fd43B526"
  ["MultiSendCallOnly"]="0x9641d764fc13c8B624c04430C7356C1C7C8102e2"
  ["CompatibilityFallbackHandler"]="0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99"
  ["CreateCall"]="0x9b35Af71d77eaf8d7e40252370304687390A1A52"
  ["SignMessageLib"]="0xd53cd0aB83D845Ac265BE939c57F53AD838012c9"
  ["SimulateTxAccessor"]="0x3d4BA2E0884aa488718476ca2FB8Efc291A46199"
)

# Gas limits per contract
declare -A GAS_LIMITS=(
  ["SafeL2"]="6000000"
  ["SafeProxyFactory"]="3000000"
  ["MultiSend"]="3000000"
  ["MultiSendCallOnly"]="3000000"
  ["CompatibilityFallbackHandler"]="3000000"
  ["CreateCall"]="3000000"
  ["SignMessageLib"]="3000000"
  ["SimulateTxAccessor"]="3000000"
)

# Verify Singleton Factory is deployed
factory_code=$(cast code "${SINGLETON_FACTORY}" --rpc-url "${RPC_URL}" 2>/dev/null || true)
if [[ -z "${factory_code}" || "${factory_code}" == "0x" ]]; then
  echo "Error: Singleton Factory not deployed at ${SINGLETON_FACTORY}"
  echo "Include it in your genesis alloc or deploy it first."
  exit 1
fi

deployed=0
skipped=0
failed=0

for name in SafeL2 SafeProxyFactory MultiSend MultiSendCallOnly CompatibilityFallbackHandler CreateCall SignMessageLib SimulateTxAccessor; do
  addr="${CONTRACTS[$name]}"
  gas="${GAS_LIMITS[$name]}"
  initcode_file="${INITCODES_DIR}/${name}.hex"

  if [[ ! -f "${initcode_file}" ]]; then
    echo "MISSING: ${initcode_file}"
    failed=$((failed + 1))
    continue
  fi

  # Check if already deployed
  code=$(cast code "${addr}" --rpc-url "${RPC_URL}" 2>/dev/null || true)
  if [[ -n "${code}" && "${code}" != "0x" ]]; then
    echo "SKIP:    ${name} already deployed at ${addr}"
    skipped=$((skipped + 1))
    continue
  fi

  # Build calldata: salt (32 zero bytes) || initCode (NO function selector)
  initcode=$(tr -d '[:space:]' < "${initcode_file}")
  # Strip 0x prefix from initcode if present (SALT already has 0x prefix)
  initcode="${initcode#0x}"
  calldata="${SALT}${initcode}"

  echo -n "DEPLOY:  ${name} -> ${addr} ... "
  if cast send "${SINGLETON_FACTORY}" "${calldata}" \
    --rpc-url "${RPC_URL}" \
    --private-key "${PRIVATE_KEY}" \
    --gas-limit "${gas}" \
    > /dev/null 2>&1; then

    # Verify deployment
    verify_code=$(cast code "${addr}" --rpc-url "${RPC_URL}" 2>/dev/null || true)
    if [[ -n "${verify_code}" && "${verify_code}" != "0x" ]]; then
      echo "OK"
      deployed=$((deployed + 1))
    else
      echo "FAILED (no code at expected address)"
      failed=$((failed + 1))
    fi
  else
    echo "FAILED (tx reverted)"
    failed=$((failed + 1))
  fi
done

echo ""
echo "Summary: ${deployed} deployed, ${skipped} already existed, ${failed} failed"

if [[ ${failed} -gt 0 ]]; then
  exit 1
fi
exit 0
