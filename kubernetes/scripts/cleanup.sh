#!/usr/bin/env bash
# Cleanup Avalanche Kubernetes resources.
set -euo pipefail

echo "Cleaning up Avalanche Kubernetes resources..."

# Release names (new + backward-compatible old names)
releases=(
  "l1-validators"
  "l1-rpc"
  "primary-validators"
  "primary-rpc"
  "monitoring"
  "validators"
  "rpc"
)

echo "Removing Helm releases..."
for release in "${releases[@]}"; do
  helm uninstall "$release" >/dev/null 2>&1 || true
done

echo "Removing ConfigMaps..."
kubectl delete configmap l1-config >/dev/null 2>&1 || true

pvcs="$(kubectl get pvc \
  -l 'app.kubernetes.io/name in (l1-validator,l1-rpc,primary-network-validator,primary-network-rpc,avalanche-validator,avalanche-rpc)' \
  -o name 2>/dev/null || true)"

if [[ -n "$pvcs" ]]; then
    echo ""
    echo "Found PersistentVolumeClaims:"
    echo "$pvcs"
    echo ""
    read -r -p "Delete PVCs? This will delete chain data. (y/N) " reply
    if [[ "$reply" =~ ^[Yy]$ ]]; then
        kubectl delete pvc \
          -l 'app.kubernetes.io/name in (l1-validator,l1-rpc,primary-network-validator,primary-network-rpc,avalanche-validator,avalanche-rpc)' \
          >/dev/null 2>&1 || true
        echo "PVCs deleted."
    else
        echo "PVCs preserved."
    fi
fi

if kind get clusters 2>/dev/null | grep -q '^avalanche-l1$'; then
    echo ""
    read -r -p "Delete kind cluster 'avalanche-l1'? (y/N) " reply
    if [[ "$reply" =~ ^[Yy]$ ]]; then
        kind delete cluster --name avalanche-l1
        echo "kind cluster deleted."
    fi
fi

echo ""
echo "Cleanup complete."
