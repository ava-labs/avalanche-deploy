#!/usr/bin/env bash
# Create a kind cluster for local Avalanche Kubernetes testing.
set -euo pipefail

CLUSTER_NAME="avalanche-l1"

usage() {
    cat <<USAGE
Usage: $0 [options]
  --name=NAME            kind cluster name (default: avalanche-l1)
  -h, --help             Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name=*) CLUSTER_NAME="${1#*=}"; shift ;;
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

echo "Creating kind cluster: $CLUSTER_NAME"

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    echo "Cluster $CLUSTER_NAME already exists"
    echo "Delete with: kind delete cluster --name $CLUSTER_NAME"
    exit 1
fi

cat <<EOF_KIND | kind create cluster --name "$CLUSTER_NAME" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 31651
        hostPort: 9651
        protocol: TCP
      - containerPort: 31650
        hostPort: 9650
        protocol: TCP
  - role: worker
  - role: worker
  - role: worker
EOF_KIND

echo ""
echo "Cluster created. Waiting for nodes..."
kubectl wait --for=condition=Ready nodes --all --timeout=120s

echo ""
echo "============================================"
echo "  kind cluster '$CLUSTER_NAME' is ready"
echo "============================================"
echo ""
echo "Next steps:"
echo "  1. Deploy L1 validators:"
echo "     helm install l1-validators ./helm/avalanche-validator --set l1_validator_replicas=3 --set network=fuji"
echo ""
echo "  2. Wait for sync:"
echo "     ./scripts/wait-for-sync.sh --release=l1-validators"
echo ""
echo "  3. Create/configure L1:"
echo "     export AVALANCHE_PRIVATE_KEY=\"PrivateKey-...\""
echo "     ./scripts/create-l1.sh --release=l1-validators --chain-name=mychain"
echo "     ./scripts/configure-l1.sh --release=l1-validators --env=l1.env"
