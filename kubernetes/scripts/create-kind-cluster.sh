#!/usr/bin/env bash
# Create a kind cluster for local Avalanche Kubernetes testing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CLUSTER_NAME="avalanche-l1"
DEFAULT_NODE_IMAGE="kindest/node:v1.34.0"
SECONDARY_FALLBACK_NODE_IMAGE="${KIND_SECONDARY_FALLBACK_NODE_IMAGE:-kindest/node:v1.33.0}"
NODE_IMAGE="${KIND_NODE_IMAGE:-$DEFAULT_NODE_IMAGE}"
WORKER_COUNT="${KIND_WORKER_COUNT:-1}"
HOST_HTTP_PORT="${KIND_HOST_HTTP_PORT:-9650}"
HOST_STAKING_PORT="${KIND_HOST_STAKING_PORT:-9651}"
MAP_HOST_PORTS="${KIND_MAP_HOST_PORTS:-false}"
VERBOSE="false"
RETAIN_ON_FAILURE="true"

usage() {
    cat <<USAGE
Usage: $0 [options]
  --name=NAME            kind cluster name (default: avalanche-l1)
  --image=REF            kind node image (default: ${NODE_IMAGE})
  --workers=N            number of worker nodes (default: ${WORKER_COUNT})
  --map-host-ports       map host ports for API/P2P access on control-plane
  --no-map-host-ports    disable host port mapping (default)
  --http-port=N          host port mapped to node HTTP API (default: ${HOST_HTTP_PORT})
  --staking-port=N       host port mapped to node staking/P2P (default: ${HOST_STAKING_PORT})
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
        --map-host-ports) MAP_HOST_PORTS="true"; shift ;;
        --no-map-host-ports) MAP_HOST_PORTS="false"; shift ;;
        --http-port=*) HOST_HTTP_PORT="${1#*=}"; shift ;;
        --staking-port=*) HOST_STAKING_PORT="${1#*=}"; shift ;;
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

if [[ "$MAP_HOST_PORTS" != "true" && "$MAP_HOST_PORTS" != "false" ]]; then
    echo "Error: KIND_MAP_HOST_PORTS must be true or false"
    exit 1
fi

if ! [[ "$HOST_HTTP_PORT" =~ ^[0-9]+$ ]] || ! [[ "$HOST_STAKING_PORT" =~ ^[0-9]+$ ]]; then
    echo "Error: --http-port and --staking-port must be integers"
    exit 1
fi

if [[ "$HOST_HTTP_PORT" -lt 1 || "$HOST_HTTP_PORT" -gt 65535 || "$HOST_STAKING_PORT" -lt 1 || "$HOST_STAKING_PORT" -gt 65535 ]]; then
    echo "Error: port values must be in range 1-65535"
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

port_in_use() {
    local port="$1"
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
        return $?
    fi
    if command -v nc >/dev/null 2>&1; then
        nc -z localhost "$port" >/dev/null 2>&1
        return $?
    fi
    return 1
}

choose_fallback_image() {
    local current_image="$1"
    if [[ "$current_image" != "$DEFAULT_NODE_IMAGE" ]]; then
        echo "$DEFAULT_NODE_IMAGE"
        return 0
    fi

    if [[ "$current_image" != "$SECONDARY_FALLBACK_NODE_IMAGE" ]]; then
        echo "$SECONDARY_FALLBACK_NODE_IMAGE"
        return 0
    fi

    return 1
}

check_docker_api_health() {
    local probe_name="kind-docker-api-probe-${RANDOM}${RANDOM}"
    if ! docker run -d --name "$probe_name" --entrypoint /bin/sh "$NODE_IMAGE" -c 'echo docker-api-probe-ok; sleep 20' >/dev/null 2>&1; then
        echo "Warning: skipped Docker API probe (failed to start probe container)."
        return 0
    fi

    sleep 1
    local inspect_ok="true"
    local logs_ok="true"

    if ! docker inspect "$probe_name" >/dev/null 2>&1; then
        inspect_ok="false"
    fi
    if ! docker logs "$probe_name" >/dev/null 2>&1; then
        logs_ok="false"
    fi

    docker rm -f "$probe_name" >/dev/null 2>&1 || true

    if [[ "$inspect_ok" != "true" || "$logs_ok" != "true" ]]; then
        echo ""
        echo "Error: Docker API health check failed."
        echo "  - docker ps can return containers, but docker inspect/logs cannot resolve them."
        echo "  - kind requires inspect/logs during node bootstrap and will fail with 'No such container'."
        echo ""
        echo "Fix Docker first, then retry:"
        echo "  1) Restart Docker Desktop completely"
        echo "  2) Verify Docker APIs with:"
        echo "     docker run -d --name docker-api-check alpine:3.20 sleep 30"
        echo "     docker inspect docker-api-check"
        echo "     docker logs docker-api-check"
        echo "     docker rm -f docker-api-check"
        echo "  3) Retry: ./scripts/create-kind-cluster.sh --name=$CLUSTER_NAME --workers=$WORKER_COUNT --verbose"
        return 1
    fi

    return 0
}

if [[ "$MAP_HOST_PORTS" == "true" ]]; then
    for port in "$HOST_HTTP_PORT" "$HOST_STAKING_PORT"; do
        if port_in_use "$port"; then
            echo "Error: host port $port is already in use."
            if command -v lsof >/dev/null 2>&1; then
                echo "Listener(s):"
                lsof -nP -iTCP:"$port" -sTCP:LISTEN || true
            fi
            echo ""
            echo "Use different ports, e.g.:"
            echo "  ./scripts/create-kind-cluster.sh --name=$CLUSTER_NAME --map-host-ports --http-port=19650 --staking-port=19651"
            exit 1
        fi
    done
fi

echo "Creating kind cluster: $CLUSTER_NAME"
echo "Node image: $NODE_IMAGE"
echo "Workers: $WORKER_COUNT"
if [[ "$MAP_HOST_PORTS" == "true" ]]; then
    echo "Host HTTP port: $HOST_HTTP_PORT"
    echo "Host staking port: $HOST_STAKING_PORT"
else
    echo "Host port mapping: disabled (use kubectl port-forward)"
fi

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    echo "Cluster $CLUSTER_NAME already exists"
    echo "Delete with: kind delete cluster --name $CLUSTER_NAME"
    exit 1
fi

echo "Pre-pulling node image (can take several minutes on first run)..."
docker pull "$NODE_IMAGE"

if ! check_docker_api_health; then
    exit 1
fi

run_kind_create() {
    local workers="$1"
    local image="$2"
    local kind_config
    kind_config="$(mktemp)"
    trap 'rm -f "$kind_config"' RETURN

    cat >"$kind_config" <<EOF_KIND
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
EOF_KIND

    if [[ "$MAP_HOST_PORTS" == "true" ]]; then
        cat >>"$kind_config" <<EOF_KIND
    extraPortMappings:
      - containerPort: 31651
        hostPort: ${HOST_STAKING_PORT}
        protocol: TCP
      - containerPort: 31650
        hostPort: ${HOST_HTTP_PORT}
        protocol: TCP
EOF_KIND
    fi

    for _ in $(seq 1 "$workers"); do
        echo "  - role: worker" >>"$kind_config"
    done

    local kind_args
    kind_args=(create cluster --name "$CLUSTER_NAME" --image "$image")
    if [[ "$RETAIN_ON_FAILURE" == "true" ]]; then
        kind_args+=(--retain)
    fi
    if [[ "$VERBOSE" == "true" ]]; then
        kind_args+=(--verbosity 9)
    fi

    kind "${kind_args[@]}" --config="$kind_config"
}

attempt_kind_create() {
    local workers="$1"
    local image="$2"
    : >"$KIND_CREATE_LOG"
    run_kind_create "$workers" "$image" 2>&1 | tee "$KIND_CREATE_LOG"
}

KIND_CREATE_LOG="$(mktemp)"
cleanup_kind_logs() {
    rm -f "$KIND_CREATE_LOG"
}
trap cleanup_kind_logs EXIT

active_workers="$WORKER_COUNT"
active_image="$NODE_IMAGE"
created="false"

if attempt_kind_create "$active_workers" "$active_image"; then
    created="true"
else
    echo ""
    echo "kind failed while preparing cluster nodes."
    echo "Most common causes:"
    echo "  - Docker Desktop resource limits are too low (CPU/RAM/disk)"
    echo "  - Existing Docker state conflicts or low disk space"

    if grep -Eq "No such container: .*control-plane" "$KIND_CREATE_LOG"; then
        fallback_image="$(choose_fallback_image "$active_image" || true)"
        if [[ -n "${fallback_image:-}" ]]; then
            echo ""
            echo "Detected control-plane container startup failure."
            echo "Retrying automatically with fallback node image: $fallback_image"
            kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
            if docker pull "$fallback_image"; then
                active_image="$fallback_image"
                if attempt_kind_create "$active_workers" "$active_image"; then
                    created="true"
                else
                    echo ""
                    echo "Retry with fallback image failed."
                fi
            else
                echo ""
                echo "Warning: failed to pull fallback image $fallback_image"
            fi
        fi
    fi

    if [[ "$created" != "true" && "$active_workers" -gt 1 ]]; then
        echo ""
        echo "Retrying automatically with --workers=1..."
        kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
        active_workers="1"
        if ! attempt_kind_create "$active_workers" "$active_image"; then
            echo ""
            echo "Retry with --workers=1 also failed."
            echo "Recommended next steps:"
            echo "  1) Ensure Docker Desktop has enough resources (>= 8GB RAM recommended)"
            echo "  2) Cleanup and retry: kind delete cluster --name $CLUSTER_NAME"
            echo "  3) Retry with explicit safe image: ./scripts/create-kind-cluster.sh --name=$CLUSTER_NAME --image=$DEFAULT_NODE_IMAGE --workers=1 --verbose"
            exit 1
        else
            created="true"
        fi
    fi

    if [[ "$created" != "true" ]]; then
        echo ""
        echo "Recommended next steps:"
        echo "  1) Ensure Docker Desktop has enough resources (>= 8GB RAM recommended)"
        echo "  2) Cleanup and retry: kind delete cluster --name $CLUSTER_NAME"
        echo "  3) Retry with explicit safe image: ./scripts/create-kind-cluster.sh --name=$CLUSTER_NAME --image=$DEFAULT_NODE_IMAGE --workers=1 --verbose"
        exit 1
    fi
fi

echo ""
if [[ "$active_image" != "$NODE_IMAGE" ]]; then
    echo "Using node image: $active_image"
fi
if [[ "$active_workers" != "$WORKER_COUNT" ]]; then
    echo "Using worker count: $active_workers"
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
echo "     helm upgrade --install l1-validators \"$K8S_DIR/helm/avalanche-validator\" -f \"$K8S_DIR/helm/avalanche-validator/values-kind.yaml\" --set network=fuji"
echo ""
echo "  2. Wait for sync:"
echo "     \"$K8S_DIR/scripts/wait-for-sync.sh\" --release=l1-validators"
echo ""
echo "  3. Create/configure L1:"
echo "     # Recommended: use platform-cli keystore key"
echo "     # platform keys import --name l1-deployer"
echo "     # platform keys default --name l1-deployer"
echo "     \"$K8S_DIR/scripts/create-l1.sh\" --release=l1-validators --chain-name=mychain --key-name=l1-deployer"
echo "     \"$K8S_DIR/scripts/configure-l1.sh\" --release=l1-validators --env=l1.env"
