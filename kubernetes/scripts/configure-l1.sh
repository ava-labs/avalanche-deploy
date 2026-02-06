#!/usr/bin/env bash
# Configure Kubernetes validators to track an L1 subnet.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(dirname "$SCRIPT_DIR")"

RELEASE="l1-validators"
L1_ENV="l1.env"
TIMEOUT_SECONDS="300"

usage() {
    cat <<USAGE
Usage: $0 [options]
  --release=NAME         Helm release name for L1 validators (default: l1-validators)
  --env=FILE             Path to l1.env output file (default: l1.env)
  --timeout=SECONDS      Rollout timeout in seconds (default: 300)
  -h, --help             Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release=*) RELEASE="${1#*=}"; shift ;;
        --env=*) L1_ENV="${1#*=}"; shift ;;
        --timeout=*) TIMEOUT_SECONDS="${1#*=}"; shift ;;
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

if [[ ! -f "$L1_ENV" ]]; then
    echo "Error: $L1_ENV not found"
    echo "Run ./scripts/create-l1.sh first"
    exit 1
fi

# shellcheck disable=SC1090
source "$L1_ENV"

if [[ -z "${SUBNET_ID:-}" || -z "${CHAIN_ID:-}" ]]; then
    echo "Error: SUBNET_ID or CHAIN_ID missing from $L1_ENV"
    exit 1
fi

echo "Configuring validators for L1..."
echo "  Release:   $RELEASE"
echo "  Subnet ID: $SUBNET_ID"
echo "  Chain ID:  $CHAIN_ID"
echo ""

PODS="$(kubectl get pods -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/name=l1-validator" -o jsonpath='{.items[*].metadata.name}')"
if [[ -z "$PODS" ]]; then
    echo "No L1 validator pods found for release: $RELEASE"
    exit 1
fi

echo "Gathering NodeIDs..."
BOOTSTRAP_IDS=""
BOOTSTRAP_IPS=""

for pod in $PODS; do
    response="$(kubectl exec "$pod" -- curl -s localhost:9650/ext/info \
        -X POST -H 'content-type:application/json' \
        -d '{"jsonrpc":"2.0","id":1,"method":"info.getNodeID"}')"

    node_id="$(echo "$response" | sed -n 's/.*"nodeID":"\([^"]*\)".*/\1/p')"
    pod_ip="$(kubectl get pod "$pod" -o jsonpath='{.status.podIP}')"

    if [[ -z "$node_id" ]]; then
        echo "Failed to read NodeID from pod: $pod"
        exit 1
    fi

    echo "  $pod: $node_id ($pod_ip)"

    if [[ -n "$BOOTSTRAP_IDS" ]]; then
        BOOTSTRAP_IDS="$BOOTSTRAP_IDS,$node_id"
        BOOTSTRAP_IPS="$BOOTSTRAP_IPS,$pod_ip:9651"
    else
        BOOTSTRAP_IDS="$node_id"
        BOOTSTRAP_IPS="$pod_ip:9651"
    fi
done

echo ""
echo "Updating L1 ConfigMap..."
kubectl create configmap l1-config \
    --from-literal="SUBNET_ID=$SUBNET_ID" \
    --from-literal="CHAIN_ID=$CHAIN_ID" \
    --from-literal="BOOTSTRAP_IDS=$BOOTSTRAP_IDS" \
    --from-literal="BOOTSTRAP_IPS=$BOOTSTRAP_IPS" \
    --dry-run=client -o yaml | kubectl apply -f -

echo "Upgrading Helm release..."
helm upgrade "$RELEASE" "$K8S_DIR/helm/avalanche-validator" \
    --reuse-values \
    --set "l1.enabled=true" \
    --set "l1.subnetId=$SUBNET_ID" \
    --set "l1.chainId=$CHAIN_ID" \
    --set "l1.bootstrapIds=$BOOTSTRAP_IDS" \
    --set "l1.bootstrapIps=$BOOTSTRAP_IPS"

statefulset_name="$(kubectl get statefulset -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/name=l1-validator" -o jsonpath='{.items[0].metadata.name}')"
if [[ -z "$statefulset_name" ]]; then
    echo "Could not find L1 validator StatefulSet for release: $RELEASE"
    exit 1
fi

echo ""
echo "Waiting for rollout: $statefulset_name"
kubectl rollout status "statefulset/$statefulset_name" --timeout="${TIMEOUT_SECONDS}s"

echo ""
echo "Verifying L1 RPC on validator pods..."
sleep 10

new_pods="$(kubectl get pods -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/name=l1-validator" -o jsonpath='{.items[*].metadata.name}')"
for pod in $new_pods; do
    chain_response="$(kubectl exec "$pod" -- curl -s "localhost:9650/ext/bc/$CHAIN_ID/rpc" \
        -X POST -H 'content-type:application/json' \
        -d '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' || true)"

    if echo "$chain_response" | grep -q '"result"'; then
        echo "  $pod: L1 ready"
    else
        echo "  $pod: L1 not ready yet"
    fi
done

echo ""
echo "Done. L1 is configured."
echo "RPC endpoint (port-forward):"
echo "  kubectl port-forward svc/$RELEASE 9650:9650"
echo "  curl localhost:9650/ext/bc/$CHAIN_ID/rpc -X POST -H 'content-type:application/json' -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_chainId\",\"params\":[]}'"
