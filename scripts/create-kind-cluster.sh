#!/usr/bin/env bash
# Compatibility wrapper: run the Kubernetes kind cluster creator from repo root.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
K8S_SCRIPT="$REPO_ROOT/kubernetes/scripts/create-kind-cluster.sh"

if [[ ! -x "$K8S_SCRIPT" ]]; then
    echo "Error: Kubernetes script not found or not executable: $K8S_SCRIPT"
    exit 1
fi

exec "$K8S_SCRIPT" "$@"
