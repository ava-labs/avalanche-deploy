#!/usr/bin/env bash
# Create a kind cluster for local Avalanche Kubernetes testing.
set -euo pipefail

CLUSTER_NAME="avalanche-l1"
NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:v1.35.0}"
WORKER_COUNT="${KIND_WORKER_COUNT:-3}"
VERBOSE="false"
RETAIN_ON_FAILURE="true"

usage() {
    cat <<USAGE
Usage: $0 [options]
  --name=NAME            kind cluster name (default: avalanche-l1)
  --image=REF            kind node image (default: ${NODE_IMAGE})
  --workers=N            number of worker nodes (default: ${WORKER_COUNT})
  --verbose              enable kind verbose logs
  --retain               keep failed cluster nodes for debugging (default)
  --no-retain            delete failed cluster nodes automatically
  -h, --help             Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name=*) CLUSTER_NAME="${1#*=}"; shift ;;
        --image=*) NODE_IMAGE="${1#*=}"; shift ;;
        --workers=*) WORKER_COUNT="${1#*=}"; shift ;;
        --verbose) VERBOSE="true"; shift ;;
        --retain) RETAIN_ON_FAILURE="true"; shift ;;
        --no-retain) RETAIN_ON_FAILURE="false"; shift ;;
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

if ! [[ "$WORKER_COUNT" =~ ^[0-9]+$ ]]; then
    echo "Error: --workers must be a non-negative integer"
    exit 1
fi

for cmd in kind docker kubectl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: required command not found: $cmd"
        exit 1
    fi
done

if ! docker info >/dev/null 2>&1; then
    echo "Error: Docker daemon is not reachable."
    echo "Make sure Docker Desktop is running and your user can access docker.sock."
    exit 1
fi

echo "Creating kind cluster: $CLUSTER_NAME"
echo "Node image: $NODE_IMAGE"
echo "Workers: $WORKER_COUNT"

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    echo "Cluster $CLUSTER_NAME already exists"
    echo "Delete with: kind delete cluster --name $CLUSTER_NAME"
    exit 1
fi

echo "Pre-pulling node image (can take several minutes on first run)..."
docker pull "$NODE_IMAGE"

KIND_ARGS=(create cluster --name "$CLUSTER_NAME" --image "$NODE_IMAGE")
if [[ "$RETAIN_ON_FAILURE" == "true" ]]; then
    KIND_ARGS+=(--retain)
fi
if [[ "$VERBOSE" == "true" ]]; then
    KIND_ARGS+=(--verbosity 9)
fi

KIND_CONFIG="$(mktemp)"
cleanup_tmp() {
    rm -f "$KIND_CONFIG"
}
trap cleanup_tmp EXIT

cat >"$KIND_CONFIG" <<EOF_KIND
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
EOF_KIND

for _ in $(seq 1 "$WORKER_COUNT"); do
    echo "  - role: worker" >>"$KIND_CONFIG"
done

if ! kind "${KIND_ARGS[@]}" --config="$KIND_CONFIG"; then
    echo ""
    echo "kind failed while preparing cluster nodes."
    echo "Most common causes:"
    echo "  - Docker Desktop resource limits are too low (CPU/RAM/disk)"
    echo "  - Existing Docker state conflicts or low disk space"
    echo ""
    echo "Recommended next attempts:"
    echo "  1) Reduce worker count: ./scripts/create-kind-cluster.sh --name=$CLUSTER_NAME --workers=1 --verbose"
    echo "  2) Ensure Docker Desktop has enough resources (>= 8GB RAM recommended)"
    echo "  3) Cleanup and retry: kind delete cluster --name $CLUSTER_NAME"
    exit 1
fi

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
