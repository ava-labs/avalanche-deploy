#!/bin/bash
# Cleanup Avalanche Kubernetes resources
set -e

echo "Cleaning up Avalanche K8s resources..."

# Uninstall helm releases
echo "Removing Helm releases..."
helm uninstall validators 2>/dev/null || true
helm uninstall rpc 2>/dev/null || true
helm uninstall monitoring 2>/dev/null || true

# Delete ConfigMaps
echo "Removing ConfigMaps..."
kubectl delete configmap l1-config 2>/dev/null || true

# Delete PVCs (optional - prompts first)
PVCS=$(kubectl get pvc -l app.kubernetes.io/name=avalanche-validator -o name 2>/dev/null)
if [ -n "$PVCS" ]; then
    echo ""
    echo "Found PersistentVolumeClaims:"
    echo "$PVCS"
    echo ""
    read -p "Delete PVCs? This will delete all chain data! (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        kubectl delete pvc -l app.kubernetes.io/name=avalanche-validator
        kubectl delete pvc -l app.kubernetes.io/name=avalanche-rpc 2>/dev/null || true
        echo "PVCs deleted."
    else
        echo "PVCs preserved."
    fi
fi

# Delete kind cluster (if exists)
if kind get clusters 2>/dev/null | grep -q "avalanche-l1"; then
    echo ""
    read -p "Delete kind cluster 'avalanche-l1'? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        kind delete cluster --name avalanche-l1
        echo "kind cluster deleted."
    fi
fi

echo ""
echo "Cleanup complete!"
