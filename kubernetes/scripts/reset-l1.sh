#!/usr/bin/env bash
# Reset L1 chain data in Kubernetes - wipes chain DB and subnet tracking config.
# Preserves staking keys. Prepare nodes for a fresh L1 creation.
#
# This is a DESTRUCTIVE operation. It will:
#   1. Scale down validator and RPC StatefulSets to 0
#   2. Delete L1 chain data from each PVC (preserving staking keys)
#   3. Remove subnet tracking configuration from Helm
#   4. Scale back up
#
# Usage:
#   ./reset-l1.sh
#   ./reset-l1.sh --release=l1-validators
#   ./reset-l1.sh --release=l1-validators --rpc-release=l1-rpc
#   ./reset-l1.sh --release=l1-validators --yes  # Skip confirmation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(dirname "$SCRIPT_DIR")"

RELEASE="l1-validators"
RPC_RELEASE=""
SKIP_CONFIRM="false"

usage() {
    cat <<USAGE
Usage: $0 [options]
  --release=NAME         Helm release name for validators (default: l1-validators)
  --rpc-release=NAME     Helm release name for RPC nodes (optional)
  --yes                  Skip confirmation prompt
  -h, --help             Show this help

WARNING: This is a destructive operation that wipes L1 chain data.
         Staking keys are preserved.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release=*) RELEASE="${1#*=}"; shift ;;
        --rpc-release=*) RPC_RELEASE="${1#*=}"; shift ;;
        --yes) SKIP_CONFIRM="true"; shift ;;
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

# Colors
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[1;33m'
reset='\033[0m'

echo "============================================"
echo -e "  ${red}L1 Reset${reset}"
echo "============================================"
echo ""
echo "  Validator Release: $RELEASE"
if [[ -n "$RPC_RELEASE" ]]; then
    echo "  RPC Release:       $RPC_RELEASE"
fi
echo ""

# Show what will be affected
validator_pods="$(kubectl get pods -l "app.kubernetes.io/instance=$RELEASE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
rpc_pods=""
if [[ -n "$RPC_RELEASE" ]]; then
    rpc_pods="$(kubectl get pods -l "app.kubernetes.io/instance=$RPC_RELEASE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
fi

echo "Affected validator pods:"
if [[ -n "$validator_pods" ]]; then
    for pod in $validator_pods; do
        echo "  - $pod"
    done
else
    echo "  (none found)"
fi

if [[ -n "$RPC_RELEASE" ]]; then
    echo ""
    echo "Affected RPC pods:"
    if [[ -n "$rpc_pods" ]]; then
        for pod in $rpc_pods; do
            echo "  - $pod"
        done
    else
        echo "  (none found)"
    fi
fi

# Read current L1 config
subnet_id="$(kubectl get configmap l1-config -o jsonpath='{.data.SUBNET_ID}' 2>/dev/null || true)"
chain_id="$(kubectl get configmap l1-config -o jsonpath='{.data.CHAIN_ID}' 2>/dev/null || true)"

if [[ -n "$subnet_id" ]]; then
    echo ""
    echo "Current L1 config:"
    echo "  Subnet ID: $subnet_id"
    echo "  Chain ID:  $chain_id"
fi

echo ""
echo -e "${red}This will DELETE all L1 chain data. Staking keys will be preserved.${reset}"
echo ""

if [[ "$SKIP_CONFIRM" != "true" ]]; then
    read -r -p "Are you sure you want to proceed? (type 'yes' to confirm) " reply
    if [[ "$reply" != "yes" ]]; then
        echo "Aborted."
        exit 0
    fi
    echo ""
fi

# --- Step 1: Scale down ---

echo "Step 1: Scaling down StatefulSets..."

validator_sts="$(kubectl get statefulset -l "app.kubernetes.io/instance=$RELEASE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
rpc_sts=""
if [[ -n "$RPC_RELEASE" ]]; then
    rpc_sts="$(kubectl get statefulset -l "app.kubernetes.io/instance=$RPC_RELEASE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
fi

# Record original replica counts for scaling back up
declare -A original_replicas

for sts in $validator_sts; do
    replicas="$(kubectl get statefulset "$sts" -o jsonpath='{.spec.replicas}')"
    original_replicas["$sts"]="$replicas"
    echo "  Scaling $sts to 0 (was $replicas)"
    kubectl scale statefulset "$sts" --replicas=0
done

for sts in $rpc_sts; do
    replicas="$(kubectl get statefulset "$sts" -o jsonpath='{.spec.replicas}')"
    original_replicas["$sts"]="$replicas"
    echo "  Scaling $sts to 0 (was $replicas)"
    kubectl scale statefulset "$sts" --replicas=0
done

# Wait for pods to terminate
echo "  Waiting for pods to terminate..."
for sts in $validator_sts $rpc_sts; do
    kubectl rollout status "statefulset/$sts" --timeout=120s 2>/dev/null || true
done

# Give pods time to fully terminate
sleep 5

echo -e "  ${green}Done${reset}"
echo ""

# --- Step 2: Clean chain data from PVCs ---

echo "Step 2: Cleaning L1 chain data from PVCs..."

# We need to spawn temporary pods to access the PVCs and delete chain data.
# The PVCs follow the naming convention: data-<statefulset-name>-<ordinal>

clean_pvc() {
    local pvc_name="$1"
    local job_name="reset-l1-${pvc_name}"

    # Truncate job name to 63 chars (K8s limit)
    job_name="$(echo "$job_name" | head -c 63 | sed 's/-$//')"

    echo "  Cleaning PVC: $pvc_name"

    # Delete existing cleanup job if it exists
    kubectl delete job "$job_name" 2>/dev/null || true

    # Run a temporary pod that mounts the PVC and removes chain data
    kubectl run "$job_name" \
        --image=busybox:1.37 \
        --restart=Never \
        --overrides="$(cat <<EOF
{
  "spec": {
    "containers": [{
      "name": "cleanup",
      "image": "busybox:1.37",
      "command": ["/bin/sh", "-c",
        "echo 'Cleaning chain data from /data...' && ls -la /data/ && find /data/db -mindepth 1 -maxdepth 1 -type d ! -name staking -exec rm -rf {} + 2>/dev/null || true && rm -rf /data/db/subnets 2>/dev/null || true && echo 'Chain data cleaned. Remaining:' && ls -la /data/db/ 2>/dev/null || echo '(db dir empty or not found)' && echo 'Done.'"
      ],
      "volumeMounts": [{
        "name": "data",
        "mountPath": "/data"
      }]
    }],
    "volumes": [{
      "name": "data",
      "persistentVolumeClaim": {
        "claimName": "$pvc_name"
      }
    }],
    "restartPolicy": "Never"
  }
}
EOF
)" 2>/dev/null

    # Wait for cleanup pod to complete
    kubectl wait --for=condition=Ready "pod/$job_name" --timeout=30s 2>/dev/null || true
    kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$job_name" --timeout=60s 2>/dev/null || true

    # Show cleanup output
    kubectl logs "$job_name" 2>/dev/null || true

    # Remove cleanup pod
    kubectl delete pod "$job_name" --force --grace-period=0 2>/dev/null || true
}

# Find all PVCs for the affected StatefulSets
for sts in $validator_sts; do
    replicas="${original_replicas[$sts]}"
    for i in $(seq 0 $((replicas - 1))); do
        pvc_name="data-${sts}-${i}"
        if kubectl get pvc "$pvc_name" >/dev/null 2>&1; then
            clean_pvc "$pvc_name"
        else
            echo "  PVC not found: $pvc_name (skipping)"
        fi
    done
done

for sts in $rpc_sts; do
    replicas="${original_replicas[$sts]}"
    for i in $(seq 0 $((replicas - 1))); do
        pvc_name="data-${sts}-${i}"
        if kubectl get pvc "$pvc_name" >/dev/null 2>&1; then
            clean_pvc "$pvc_name"
        else
            echo "  PVC not found: $pvc_name (skipping)"
        fi
    done
done

echo -e "  ${green}Done${reset}"
echo ""

# --- Step 3: Remove subnet tracking from Helm ---

echo "Step 3: Removing L1 configuration..."

# Upgrade Helm release to disable L1 tracking
helm upgrade "$RELEASE" "$K8S_DIR/helm/avalanche-validator" \
    --reuse-values \
    --set "l1.enabled=false" \
    --set "l1.subnetId=" \
    --set "l1.chainId=" \
    --set "l1.bootstrapIds=" \
    --set "l1.bootstrapIps=" 2>/dev/null || true

if [[ -n "$RPC_RELEASE" ]]; then
    helm upgrade "$RPC_RELEASE" "$K8S_DIR/helm/avalanche-validator" \
        --reuse-values \
        --set "l1.enabled=false" \
        --set "l1.subnetId=" \
        --set "l1.chainId=" \
        --set "l1.bootstrapIds=" \
        --set "l1.bootstrapIps=" 2>/dev/null || true
fi

# Delete the l1-config ConfigMap
kubectl delete configmap l1-config 2>/dev/null || true

echo -e "  ${green}Done${reset}"
echo ""

# --- Step 4: Scale back up ---

echo "Step 4: Scaling StatefulSets back up..."

for sts in $validator_sts; do
    replicas="${original_replicas[$sts]}"
    echo "  Scaling $sts to $replicas"
    kubectl scale statefulset "$sts" --replicas="$replicas"
done

for sts in $rpc_sts; do
    replicas="${original_replicas[$sts]}"
    echo "  Scaling $sts to $replicas"
    kubectl scale statefulset "$sts" --replicas="$replicas"
done

echo ""
echo "Waiting for pods to start..."
for sts in $validator_sts $rpc_sts; do
    kubectl rollout status "statefulset/$sts" --timeout=300s || true
done

echo -e "  ${green}Done${reset}"
echo ""

# --- Complete ---

echo "============================================"
echo -e "  ${green}L1 Reset Complete${reset}"
echo "============================================"
echo ""
echo "Chain data has been wiped. Staking keys are intact."
echo "Nodes are restarting without L1 tracking."
echo ""
echo "Next steps:"
echo "  1. Wait for P-Chain sync:"
echo "     $SCRIPT_DIR/wait-for-sync.sh --release=$RELEASE"
echo ""
echo "  2. Create a new L1:"
echo "     $SCRIPT_DIR/create-l1.sh --release=$RELEASE"
echo ""
echo "  3. Configure validators for the new L1:"
echo "     $SCRIPT_DIR/configure-l1.sh --release=$RELEASE --env=l1.env"
echo ""
echo "============================================"
