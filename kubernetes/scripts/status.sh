#!/usr/bin/env bash
# Check status of Avalanche nodes in Kubernetes.
set -euo pipefail

RELEASE="l1-validators"

usage() {
    cat <<USAGE
Usage: $0 [options]
  --release=NAME         Helm release name (default: l1-validators)
  -h, --help             Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release=*) RELEASE="${1#*=}"; shift ;;
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

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[1;33m'
reset='\033[0m'

echo "============================================"
echo "  Avalanche Kubernetes Status"
echo "============================================"
echo ""

pods="$(kubectl get pods -l "app.kubernetes.io/instance=$RELEASE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
if [[ -z "$pods" ]]; then
    echo -e "${red}No pods found for release: $RELEASE${reset}"
    exit 1
fi

l1_chain_id="$(kubectl get configmap l1-config -o jsonpath='{.data.CHAIN_ID}' 2>/dev/null || true)"
l1_release_pods="$(kubectl get pods -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/name=l1-validator" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
is_l1_release="false"
if [[ -n "$l1_release_pods" ]]; then
    is_l1_release="true"
fi

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

echo "--- Pods ---"
for pod in $pods; do
    pod_status="$(kubectl get pod "$pod" -o jsonpath='{.status.phase}')"
    pod_ip="$(kubectl get pod "$pod" -o jsonpath='{.status.podIP}')"

    if [[ "$pod_status" != "Running" ]]; then
        echo -e "$pod: ${red}$pod_status${reset}"
        continue
    fi

    p_boot_response="$(rpc_post "$pod" "/ext/info" '{"jsonrpc":"2.0","id":1,"method":"info.isBootstrapped","params":{"chain":"P"}}')"
    p_boot="$(echo "$p_boot_response" | sed -n 's/.*"isBootstrapped":\([^,}]*\).*/\1/p')"

    node_id_response="$(rpc_post "$pod" "/ext/info" '{"jsonrpc":"2.0","id":1,"method":"info.getNodeID"}')"
    node_id="$(echo "$node_id_response" | sed -n 's/.*"nodeID":"\([^"]*\)".*/\1/p')"

    if [[ "$p_boot" == "true" ]]; then
        status="${green}READY${reset}"
        p_status="${green}OK${reset}"
    else
        status="${yellow}SYNCING${reset}"
        p_status="${yellow}...${reset}"
    fi

    echo -e "$pod ($pod_ip)"
    echo -e "  Status: $status  [P:$p_status]"
    echo "  NodeID: $node_id"

    if [[ -n "$l1_chain_id" && "$is_l1_release" == "true" ]]; then
        l1_response="$(rpc_post "$pod" "/ext/bc/$l1_chain_id/rpc" '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}')"
        l1_block="$(echo "$l1_response" | sed -n 's/.*"result":"\([^"]*\)".*/\1/p')"

        if [[ -n "$l1_block" ]]; then
            block_dec="$((l1_block))"
            echo -e "  L1:     ${green}ACTIVE${reset} (block $block_dec)"
        else
            echo -e "  L1:     ${yellow}NOT READY${reset}"
        fi
    fi
    echo ""
done

echo "============================================"
if [[ -n "$l1_chain_id" && "$is_l1_release" == "true" ]]; then
    subnet_id="$(kubectl get configmap l1-config -o jsonpath='{.data.SUBNET_ID}' 2>/dev/null || true)"
    echo "Subnet ID: $subnet_id"
    echo "Chain ID:  $l1_chain_id"
    echo ""
    echo "RPC (port-forward):"
    echo "  kubectl port-forward svc/$RELEASE 9650:9650"
    echo "  http://localhost:9650/ext/bc/$l1_chain_id/rpc"
else
    echo "L1 not configured yet."
    echo "Run ./scripts/create-l1.sh after nodes sync."
fi
echo "============================================"
