#!/usr/bin/env bash
# Configure Kubernetes validators and RPC nodes to track an Avalanche Deploy L1.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(dirname "$SCRIPT_DIR")"

VALIDATOR_RELEASE="l1-validators"
RPC_RELEASE="l1-rpc"
NAMESPACE=""
L1_ENV="l1.env"
TIMEOUT_SECONDS="300"
L1_IMAGE_REPOSITORY="avaplatform/subnet-evm_avalanchego"
L1_IMAGE_TAG="v0.8.0_v1.14.0"

usage() {
    cat <<USAGE
Usage: $0 [options]
  --release=NAME         Helm release name for L1 validators (default: l1-validators)
  --rpc-release=NAME     Helm release name for L1 RPC nodes (default: l1-rpc)
  --namespace=NAME       Kubernetes namespace (default: current context namespace)
  --env=FILE             Path to l1.env output file (default: l1.env)
  --timeout=SECONDS      Rollout timeout in seconds (default: 300)
  --image-repo=IMAGE     AvalancheGo image repository override
  --image-tag=TAG        AvalancheGo image tag override
  -h, --help             Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release=*) VALIDATOR_RELEASE="${1#*=}"; shift ;;
        --rpc-release=*) RPC_RELEASE="${1#*=}"; shift ;;
        --namespace=*) NAMESPACE="${1#*=}"; shift ;;
        --env=*) L1_ENV="${1#*=}"; shift ;;
        --timeout=*) TIMEOUT_SECONDS="${1#*=}"; shift ;;
        --image-repo=*) L1_IMAGE_REPOSITORY="${1#*=}"; shift ;;
        --image-tag=*) L1_IMAGE_TAG="${1#*=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

for cmd in curl helm jq kubectl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: $cmd not found in PATH"
        exit 1
    fi
done

if [[ ! -f "$L1_ENV" ]]; then
    echo "Error: $L1_ENV not found"
    echo "Run ./scripts/create-l1.sh first."
    exit 1
fi

if [[ -z "$NAMESPACE" ]]; then
    NAMESPACE="$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null || true)"
    NAMESPACE="${NAMESPACE:-default}"
fi

env_value() {
    local key="$1"
    awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$L1_ENV"
}

existing_config_value() {
    local key="$1"
    kubectl -n "$NAMESPACE" get configmap l1-config -o json 2>/dev/null | \
        jq -r --arg key "$key" '.data[$key] // empty' 2>/dev/null || true
}

SUBNET_ID="$(env_value SUBNET_ID)"
CHAIN_ID="$(env_value CHAIN_ID)"
EVM_CHAIN_ID="$(env_value EVM_CHAIN_ID)"
CHAIN_NAME="$(env_value CHAIN_NAME)"
NETWORK="$(env_value NETWORK)"
VALIDATOR_MANAGER_IMPL="$(env_value VALIDATOR_MANAGER_IMPL)"
VALIDATOR_MANAGER_PROXY="$(env_value VALIDATOR_MANAGER_PROXY)"
POA_MANAGER="$(env_value POA_MANAGER)"
VALIDATOR_MANAGER_IMPL="${VALIDATOR_MANAGER_IMPL:-$(existing_config_value VALIDATOR_MANAGER_IMPL)}"
VALIDATOR_MANAGER_PROXY="${VALIDATOR_MANAGER_PROXY:-$(existing_config_value VALIDATOR_MANAGER_PROXY)}"
POA_MANAGER="${POA_MANAGER:-$(existing_config_value POA_MANAGER)}"

missing=()
[[ -z "$SUBNET_ID" ]] && missing+=(SUBNET_ID)
[[ -z "$CHAIN_ID" ]] && missing+=(CHAIN_ID)
[[ -z "$EVM_CHAIN_ID" ]] && missing+=(EVM_CHAIN_ID)
[[ -z "$CHAIN_NAME" ]] && missing+=(CHAIN_NAME)
[[ -z "$NETWORK" ]] && missing+=(NETWORK)
if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Error: required L1 metadata missing from $L1_ENV: ${missing[*]}"
    echo "Re-run create-l1.sh with the generated genesis file."
    exit 1
fi
if [[ "$NETWORK" != "fuji" && "$NETWORK" != "mainnet" ]]; then
    echo "Error: NETWORK must be fuji or mainnet in $L1_ENV (found: $NETWORK)"
    exit 1
fi

for release in "$VALIDATOR_RELEASE" "$RPC_RELEASE"; do
    if ! helm status "$release" -n "$NAMESPACE" >/dev/null 2>&1; then
        echo "Error: Helm release '$release' was not found in namespace '$NAMESPACE'."
        echo "Run make k8s-l1-deploy before configuring the L1."
        exit 1
    fi
done

rpc_post() {
    local pod="$1"
    local endpoint="$2"
    local payload="$3"
    local pf_port pf_pid response=""
    pf_port="$((20000 + RANDOM % 20000))"

    kubectl -n "$NAMESPACE" port-forward --address 127.0.0.1 "pod/$pod" "${pf_port}:9650" >/dev/null 2>&1 &
    pf_pid=$!
    for _ in $(seq 1 40); do
        response="$(curl --noproxy '*' -fsS "http://127.0.0.1:${pf_port}${endpoint}" \
            -X POST -H 'content-type:application/json' -d "$payload" 2>/dev/null || true)"
        [[ -n "$response" ]] && break
        sleep 0.25
    done
    kill "$pf_pid" >/dev/null 2>&1 || true
    wait "$pf_pid" >/dev/null 2>&1 || true
    printf '%s\n' "$response"
}

echo "Configuring Avalanche Deploy L1 in namespace '$NAMESPACE'..."
echo "  Validator release: $VALIDATOR_RELEASE"
echo "  RPC release:       $RPC_RELEASE"
echo "  Subnet ID:         $SUBNET_ID"
echo "  Blockchain ID:     $CHAIN_ID"

gather_validator_peers() {
    local pods pod response node_id pod_ip pod_count=0
    pods="$(kubectl -n "$NAMESPACE" get pods \
        -l "app.kubernetes.io/instance=$VALIDATOR_RELEASE,app.kubernetes.io/name=l1-validator" \
        --field-selector=status.phase=Running -o json | jq -r '.items | sort_by(.metadata.name)[] | .metadata.name')"
    if [[ -z "$pods" ]]; then
        echo "Error: no running L1 validator pods found for release '$VALIDATOR_RELEASE' in namespace '$NAMESPACE'."
        exit 1
    fi

    BOOTSTRAP_IDS=""
    BOOTSTRAP_IPS=""
    VALIDATOR_PEERS=""
    echo "Gathering validator peers..."
    for pod in $pods; do
        response="$(rpc_post "$pod" /ext/info '{"jsonrpc":"2.0","id":1,"method":"info.getNodeID"}')"
        node_id="$(jq -r '.result.nodeID // empty' <<<"$response")"
        pod_ip="$(kubectl -n "$NAMESPACE" get pod "$pod" -o jsonpath='{.status.podIP}')"
        if [[ -z "$node_id" || -z "$pod_ip" ]]; then
            echo "Error: failed to discover NodeID or pod IP for validator '$pod'."
            exit 1
        fi

        pod_count=$((pod_count + 1))
        echo "  $pod: $node_id ($pod_ip:9651)"
        BOOTSTRAP_IDS="${BOOTSTRAP_IDS:+$BOOTSTRAP_IDS,}$node_id"
        BOOTSTRAP_IPS="${BOOTSTRAP_IPS:+$BOOTSTRAP_IPS,}$pod_ip:9651"
        VALIDATOR_PEERS="${VALIDATOR_PEERS:+$VALIDATOR_PEERS,}$node_id@$pod_ip:9651"
    done

    VALIDATOR_COUNT="$pod_count"
}

gather_validator_peers

validator_bootstrap_ids="$BOOTSTRAP_IDS"
validator_bootstrap_ips="$BOOTSTRAP_IPS"
if [[ "$VALIDATOR_COUNT" -le 1 ]]; then
    # The only validator must not try to bootstrap from itself. The separate RPC
    # release below still receives this validator as its bootstrap peer.
    validator_bootstrap_ids=""
    validator_bootstrap_ips=""
fi
escaped_bootstrap_ids="${validator_bootstrap_ids//,/\\,}"
escaped_bootstrap_ips="${validator_bootstrap_ips//,/\\,}"

common_helm_args=(
    --reuse-values
    --set "network=$NETWORK"
    --set "l1.enabled=true"
    --set "l1.subnetId=$SUBNET_ID"
    --set "l1.chainId=$CHAIN_ID"
    --set-string "l1.bootstrapIds=$escaped_bootstrap_ids"
    --set-string "l1.bootstrapIps=$escaped_bootstrap_ips"
)

echo "Upgrading validator release..."
helm upgrade "$VALIDATOR_RELEASE" "$K8S_DIR/helm/avalanche-validator" -n "$NAMESPACE" \
    "${common_helm_args[@]}" \
    --set "l1_validator_image.repository=$L1_IMAGE_REPOSITORY" \
    --set "l1_validator_image.tag=$L1_IMAGE_TAG"

statefulset_name="$(kubectl -n "$NAMESPACE" get statefulset \
    -l "app.kubernetes.io/instance=$VALIDATOR_RELEASE,app.kubernetes.io/name=l1-validator" \
    -o json | jq -r '.items | if length == 1 then .[0].metadata.name else empty end')"
if [[ -z "$statefulset_name" ]]; then
    echo "Error: expected one validator StatefulSet after Helm upgrade."
    exit 1
fi

kubectl -n "$NAMESPACE" rollout status "statefulset/$statefulset_name" --timeout="${TIMEOUT_SECONDS}s"

# A StatefulSet rollout may assign new pod IPs. Refresh peers before configuring
# the RPC release so bootstrap and future add-on metadata never retain stale IPs.
gather_validator_peers
escaped_bootstrap_ids="${BOOTSTRAP_IDS//,/\\,}"
escaped_bootstrap_ips="${BOOTSTRAP_IPS//,/\\,}"
common_helm_args=(
    --reuse-values
    --set "network=$NETWORK"
    --set "l1.enabled=true"
    --set "l1.subnetId=$SUBNET_ID"
    --set "l1.chainId=$CHAIN_ID"
    --set-string "l1.bootstrapIds=$escaped_bootstrap_ids"
    --set-string "l1.bootstrapIps=$escaped_bootstrap_ips"
)

echo "Upgrading RPC release so it tracks the same subnet..."
helm upgrade "$RPC_RELEASE" "$K8S_DIR/helm/avalanche-rpc" -n "$NAMESPACE" \
    "${common_helm_args[@]}" \
    --set "l1_rpc_image.repository=$L1_IMAGE_REPOSITORY" \
    --set "l1_rpc_image.tag=$L1_IMAGE_TAG" \
    --set "l1_rpc_replicas=1" \
    --set "l1_rpc_autoscaling.enabled=false"

rpc_deployment="$(kubectl -n "$NAMESPACE" get deployment \
    -l "app.kubernetes.io/instance=$RPC_RELEASE,app.kubernetes.io/name=l1-rpc" \
    -o json | jq -r '.items | if length == 1 then .[0].metadata.name else empty end')"
if [[ -z "$rpc_deployment" ]]; then
    echo "Error: expected one RPC Deployment after Helm upgrade."
    exit 1
fi
kubectl -n "$NAMESPACE" rollout status "deployment/$rpc_deployment" --timeout="${TIMEOUT_SECONDS}s"

echo "Persisting non-secret L1 metadata..."
kubectl -n "$NAMESPACE" create configmap l1-config --dry-run=client -o yaml | kubectl -n "$NAMESPACE" apply -f - >/dev/null
kubectl -n "$NAMESPACE" label configmap l1-config --overwrite \
    app.kubernetes.io/name=l1-config \
    app.kubernetes.io/instance="$VALIDATOR_RELEASE" \
    app.kubernetes.io/component=l1-metadata \
    app.kubernetes.io/part-of=avalanche-deploy >/dev/null

metadata_patch="$(jq -cn \
    --arg subnet "$SUBNET_ID" --arg chain "$CHAIN_ID" --arg evm "$EVM_CHAIN_ID" \
    --arg chainName "$CHAIN_NAME" --arg network "$NETWORK" \
    --arg bootstrapIds "$BOOTSTRAP_IDS" --arg bootstrapIps "$BOOTSTRAP_IPS" \
    --arg peers "$VALIDATOR_PEERS" --arg validatorRelease "$VALIDATOR_RELEASE" \
    --arg rpcRelease "$RPC_RELEASE" --arg vmImpl "$VALIDATOR_MANAGER_IMPL" \
    --arg vmProxy "$VALIDATOR_MANAGER_PROXY" --arg poa "$POA_MANAGER" \
    '{data: {
        SUBNET_ID: $subnet, CHAIN_ID: $chain, EVM_CHAIN_ID: $evm,
        CHAIN_NAME: $chainName, NETWORK: $network,
        BOOTSTRAP_IDS: $bootstrapIds, BOOTSTRAP_IPS: $bootstrapIps,
        VALIDATOR_PEERS: $peers, VALIDATOR_RELEASE: $validatorRelease,
        RPC_RELEASE: $rpcRelease, VALIDATOR_MANAGER_IMPL: $vmImpl,
        VALIDATOR_MANAGER_PROXY: $vmProxy, POA_MANAGER: $poa
    }}')"
kubectl -n "$NAMESPACE" patch configmap l1-config --type merge -p "$metadata_patch" >/dev/null

rpc_service="$(kubectl -n "$NAMESPACE" get service \
    -l "app.kubernetes.io/instance=$RPC_RELEASE,app.kubernetes.io/name=l1-rpc" \
    -o json | jq -r '.items | if length == 1 then .[0].metadata.name else empty end')"
if [[ -z "$rpc_service" ]]; then
    echo "Error: expected exactly one RPC Service for release '$RPC_RELEASE'."
    exit 1
fi

echo "Verifying the L1 through RPC service '$rpc_service'..."
rpc_pod="$(kubectl -n "$NAMESPACE" get pods \
    -l "app.kubernetes.io/instance=$RPC_RELEASE,app.kubernetes.io/name=l1-rpc" \
    --field-selector=status.phase=Running -o json | jq -r '.items | sort_by(.metadata.name) | .[0].metadata.name // empty')"
chain_response="$(rpc_post "$rpc_pod" "/ext/bc/$CHAIN_ID/rpc" \
    '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}')"
reported_hex="$(jq -r '.result // empty' <<<"$chain_response")"
if [[ -z "$reported_hex" || "$((reported_hex))" -ne "$EVM_CHAIN_ID" ]]; then
    echo "Error: RPC EVM chain ID did not match $EVM_CHAIN_ID."
    exit 1
fi

echo "Done. Validators and RPC nodes are tracking the L1."
echo "RPC access: kubectl -n $NAMESPACE port-forward service/$rpc_service 9650:9650"
