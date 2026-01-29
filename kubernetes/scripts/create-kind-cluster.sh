#!/bin/bash
# Create a kind cluster for local Avalanche L1 testing
set -e

CLUSTER_NAME=${1:-avalanche-l1}

echo "Creating kind cluster: $CLUSTER_NAME"

# Check if cluster exists
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    echo "Cluster $CLUSTER_NAME already exists"
    echo "Delete with: kind delete cluster --name $CLUSTER_NAME"
    exit 1
fi

# Create cluster config
cat <<EOF | kind create cluster --name $CLUSTER_NAME --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      # Staking port (P2P)
      - containerPort: 31651
        hostPort: 9651
        protocol: TCP
      # HTTP API
      - containerPort: 31650
        hostPort: 9650
        protocol: TCP
  - role: worker
  - role: worker
  - role: worker
EOF

echo ""
echo "Cluster created! Setting up..."

# Wait for nodes to be ready
kubectl wait --for=condition=Ready nodes --all --timeout=120s

echo ""
echo "============================================"
echo "  kind cluster '$CLUSTER_NAME' is ready"
echo "============================================"
echo ""
echo "Next steps:"
echo "  1. Deploy validators:"
echo "     helm install validators ./helm/avalanche-validator --set replicaCount=3"
echo ""
echo "  2. Wait for sync:"
echo "     ./scripts/wait-for-sync.sh"
echo ""
echo "  3. Access via port-forward:"
echo "     kubectl port-forward svc/validators-avalanche-validator 9650:9650"
echo ""
