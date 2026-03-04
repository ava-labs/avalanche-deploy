#!/usr/bin/env bash
# Comprehensive health checks for Avalanche nodes in Kubernetes.
#
# Checks validator and RPC pods for:
#   - Pod status (Running)
#   - avalanchego health endpoint (/ext/health)
#   - P-Chain, C-Chain, X-Chain bootstrap status
#   - Node version consistency
#   - L1 chain sync status (if chain_id provided)
#
# Usage:
#   ./health-checks.sh
#   ./health-checks.sh --release=l1-validators
#   ./health-checks.sh --release=l1-validators --chain-id=tN5qbq7...
#   ./health-checks.sh --rpc-release=l1-rpc --chain-id=tN5qbq7...
set -euo pipefail

RELEASE="l1-validators"
RPC_RELEASE=""
CHAIN_ID=""

usage() {
    cat <<USAGE
Usage: $0 [options]
  --release=NAME         Helm release name for validators (default: l1-validators)
  --rpc-release=NAME     Helm release name for RPC nodes (optional)
  --chain-id=ID          L1 chain ID to check sync status (optional; reads from l1-config ConfigMap if omitted)
  -h, --help             Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release=*) RELEASE="${1#*=}"; shift ;;
        --rpc-release=*) RPC_RELEASE="${1#*=}"; shift ;;
        --chain-id=*) CHAIN_ID="${1#*=}"; shift ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

if ! command -v curl >/dev/null 2>&1; then
    echo "Error: curl not found in PATH"
    exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
    echo "Error: kubectl not found in PATH"
    exit 1
fi

# Colors
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[1;33m'
cyan='\033[0;36m'
reset='\033[0m'

# Try to read chain ID from ConfigMap if not provided
if [[ -z "$CHAIN_ID" ]]; then
    CHAIN_ID="$(kubectl get configmap l1-config -o jsonpath='{.data.CHAIN_ID}' 2>/dev/null || true)"
fi

# --- Helper: RPC call via port-forward ---

rpc_post() {
    local pod="$1"
    local endpoint="$2"
    local payload="$3"
    local pf_port
    pf_port="$((20000 + RANDOM % 20000))"

    kubectl port-forward "pod/$pod" "${pf_port}:9650" >/dev/null 2>&1 &
    local pf_pid=$!

    local response=""
    for _ in $(seq 1 20); do
        response="$(curl -s "http://127.0.0.1:${pf_port}${endpoint}" \
            -X POST -H 'content-type:application/json' \
            -d "$payload" 2>/dev/null || true)"
        if [[ -n "$response" ]]; then
            break
        fi
        sleep 0.25
    done

    kill "$pf_pid" >/dev/null 2>&1 || true
    wait "$pf_pid" >/dev/null 2>&1 || true

    echo "$response"
}

rpc_get() {
    local pod="$1"
    local endpoint="$2"
    local pf_port
    pf_port="$((20000 + RANDOM % 20000))"

    kubectl port-forward "pod/$pod" "${pf_port}:9650" >/dev/null 2>&1 &
    local pf_pid=$!

    local response=""
    for _ in $(seq 1 20); do
        response="$(curl -s "http://127.0.0.1:${pf_port}${endpoint}" 2>/dev/null || true)"
        if [[ -n "$response" ]]; then
            break
        fi
        sleep 0.25
    done

    kill "$pf_pid" >/dev/null 2>&1 || true
    wait "$pf_pid" >/dev/null 2>&1 || true

    echo "$response"
}

# --- Collect pods ---

validator_pods="$(kubectl get pods -l "app.kubernetes.io/instance=$RELEASE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"

rpc_pods=""
if [[ -n "$RPC_RELEASE" ]]; then
    rpc_pods="$(kubectl get pods -l "app.kubernetes.io/instance=$RPC_RELEASE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
fi

all_pods="$validator_pods $rpc_pods"
all_pods="$(echo "$all_pods" | xargs)"  # trim whitespace

if [[ -z "$all_pods" ]]; then
    echo -e "${red}No pods found for release(s): $RELEASE ${RPC_RELEASE:-}${reset}"
    exit 1
fi

echo "============================================"
echo "  Avalanche Kubernetes Health Checks"
echo "============================================"
echo ""
if [[ -n "$CHAIN_ID" ]]; then
    echo "L1 Chain ID: $CHAIN_ID"
    echo ""
fi

# --- Check each pod ---

total_nodes=0
healthy_count=0
unhealthy_count=0
syncing_count=0
versions=()

check_pod() {
    local pod="$1"
    local role="$2"
    total_nodes=$((total_nodes + 1))

    local pod_status
    pod_status="$(kubectl get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    local pod_ip
    pod_ip="$(kubectl get pod "$pod" -o jsonpath='{.status.podIP}' 2>/dev/null || true)"

    echo -e "${cyan}${pod}${reset} ($role) [$pod_ip]"

    # Pod running check
    if [[ "$pod_status" != "Running" ]]; then
        echo -e "  Pod Status:    ${red}$pod_status${reset}"
        unhealthy_count=$((unhealthy_count + 1))
        echo ""
        return
    fi
    echo -e "  Pod Status:    ${green}Running${reset}"

    # Health endpoint
    local health_response
    health_response="$(rpc_get "$pod" "/ext/health")"
    local health_ok="false"
    if echo "$health_response" | grep -q '"healthy":true'; then
        health_ok="true"
        echo -e "  Health:        ${green}HEALTHY${reset}"
    else
        echo -e "  Health:        ${red}UNHEALTHY${reset}"
    fi

    # Node ID
    local node_id_response
    node_id_response="$(rpc_post "$pod" "/ext/info" '{"jsonrpc":"2.0","id":1,"method":"info.getNodeID"}')"
    local node_id
    node_id="$(echo "$node_id_response" | sed -n 's/.*"nodeID":"\([^"]*\)".*/\1/p')"
    echo "  NodeID:        ${node_id:-unknown}"

    # Node version
    local version_response
    version_response="$(rpc_post "$pod" "/ext/info" '{"jsonrpc":"2.0","id":1,"method":"info.getNodeVersion"}')"
    local version
    version="$(echo "$version_response" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')"
    echo "  Version:       ${version:-unknown}"
    if [[ -n "$version" ]]; then
        versions+=("$version")
    fi

    # P-Chain bootstrap
    local p_response
    p_response="$(rpc_post "$pod" "/ext/info" '{"jsonrpc":"2.0","id":1,"method":"info.isBootstrapped","params":{"chain":"P"}}')"
    local p_boot
    p_boot="$(echo "$p_response" | sed -n 's/.*"isBootstrapped":\([^,}]*\).*/\1/p')"
    if [[ "$p_boot" == "true" ]]; then
        echo -e "  P-Chain:       ${green}READY${reset}"
    else
        echo -e "  P-Chain:       ${yellow}SYNCING${reset}"
    fi

    # C-Chain bootstrap
    local c_response
    c_response="$(rpc_post "$pod" "/ext/info" '{"jsonrpc":"2.0","id":1,"method":"info.isBootstrapped","params":{"chain":"C"}}')"
    local c_boot
    c_boot="$(echo "$c_response" | sed -n 's/.*"isBootstrapped":\([^,}]*\).*/\1/p')"
    if [[ "$c_boot" == "true" ]]; then
        echo -e "  C-Chain:       ${green}READY${reset}"
    else
        echo -e "  C-Chain:       ${yellow}SYNCING${reset}"
    fi

    # X-Chain bootstrap
    local x_response
    x_response="$(rpc_post "$pod" "/ext/info" '{"jsonrpc":"2.0","id":1,"method":"info.isBootstrapped","params":{"chain":"X"}}')"
    local x_boot
    x_boot="$(echo "$x_response" | sed -n 's/.*"isBootstrapped":\([^,}]*\).*/\1/p')"
    if [[ "$x_boot" == "true" ]]; then
        echo -e "  X-Chain:       ${green}READY${reset}"
    else
        echo -e "  X-Chain:       ${yellow}SYNCING${reset}"
    fi

    # L1 chain sync (if chain_id provided)
    if [[ -n "$CHAIN_ID" ]]; then
        local l1_response
        l1_response="$(rpc_post "$pod" "/ext/bc/$CHAIN_ID/rpc" '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}')"
        local l1_block
        l1_block="$(echo "$l1_response" | sed -n 's/.*"result":"\([^"]*\)".*/\1/p')"

        if [[ -n "$l1_block" ]]; then
            local block_dec
            block_dec="$((l1_block))"
            echo -e "  L1 Chain:      ${green}ACTIVE${reset} (block $block_dec)"

            # Also check net_version
            local net_response
            net_response="$(rpc_post "$pod" "/ext/bc/$CHAIN_ID/rpc" '{"jsonrpc":"2.0","id":1,"method":"net_version","params":[]}')"
            local net_version
            net_version="$(echo "$net_response" | sed -n 's/.*"result":"\([^"]*\)".*/\1/p')"
            if [[ -n "$net_version" ]]; then
                echo "  L1 EVM Chain:  $net_version"
            fi
        else
            echo -e "  L1 Chain:      ${yellow}NOT READY${reset}"
        fi
    fi

    # Tally
    if [[ "$health_ok" == "true" ]]; then
        if [[ "$p_boot" == "true" ]]; then
            healthy_count=$((healthy_count + 1))
        else
            syncing_count=$((syncing_count + 1))
        fi
    else
        unhealthy_count=$((unhealthy_count + 1))
    fi

    echo ""
}

# Check validator pods
if [[ -n "$validator_pods" ]]; then
    echo "--- Validators ($RELEASE) ---"
    echo ""
    for pod in $validator_pods; do
        check_pod "$pod" "validator"
    done
fi

# Check RPC pods
if [[ -n "$rpc_pods" ]]; then
    echo "--- RPC Nodes ($RPC_RELEASE) ---"
    echo ""
    for pod in $rpc_pods; do
        check_pod "$pod" "rpc"
    done
fi

# --- Version consistency ---

echo "============================================"
echo "  Version Check"
echo "============================================"

if [[ ${#versions[@]} -gt 0 ]]; then
    unique_versions=($(printf '%s\n' "${versions[@]}" | sort -u))
    if [[ ${#unique_versions[@]} -eq 1 ]]; then
        echo -e "  All nodes running: ${green}${unique_versions[0]}${reset}"
    else
        echo -e "  ${yellow}WARNING: Mixed versions detected!${reset}"
        for v in "${unique_versions[@]}"; do
            count=0
            for cv in "${versions[@]}"; do
                if [[ "$cv" == "$v" ]]; then
                    count=$((count + 1))
                fi
            done
            echo "    $v ($count nodes)"
        done
    fi
else
    echo -e "  ${red}No version information available${reset}"
fi

echo ""

# --- Summary ---

echo "============================================"
echo "  Summary"
echo "============================================"
echo ""
echo "  Total Nodes:     $total_nodes"
echo -e "  Healthy:         ${green}$healthy_count${reset}"
if [[ $syncing_count -gt 0 ]]; then
    echo -e "  Syncing:         ${yellow}$syncing_count${reset}"
fi
if [[ $unhealthy_count -gt 0 ]]; then
    echo -e "  Unhealthy:       ${red}$unhealthy_count${reset}"
fi
echo ""

if [[ $unhealthy_count -eq 0 && $syncing_count -eq 0 ]]; then
    echo -e "  Status: ${green}ALL SYSTEMS OPERATIONAL${reset}"
elif [[ $unhealthy_count -eq 0 ]]; then
    echo -e "  Status: ${yellow}HEALTHY (some nodes still syncing)${reset}"
else
    echo -e "  Status: ${red}DEGRADED ($unhealthy_count unhealthy nodes)${reset}"
fi

echo ""
echo "============================================"

# Exit with non-zero if any nodes are unhealthy
if [[ $unhealthy_count -gt 0 ]]; then
    exit 1
fi
