#!/usr/bin/env bash
# Exercise namespace-first discovery, authorized fallback, and denial remediation.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=kubernetes/scripts/relayer.sh
source "$ROOT_DIR/kubernetes/scripts/relayer.sh"

DISCOVERY_SCENARIO=current
STORAGE_SCENARIO=bound
kubectl() {
    case "$*" in
        'config current-context') printf test-context; return 0 ;;
        *'config view --minify -o jsonpath={..namespace}'*)
            [[ "$DISCOVERY_SCENARIO" == current ]] && printf team-l1 || printf default
            return 0
            ;;
        *'-n team-l1 get configmap l1-config'*) return 0 ;;
        *'-n default get configmap l1-config'*) return 1 ;;
        *'auth can-i list configmaps --all-namespaces'*)
            [[ "$DISCOVERY_SCENARIO" == denied ]] && printf no || printf yes
            return 0
            ;;
        *'get configmaps --all-namespaces -o json'*)
            if [[ "$DISCOVERY_SCENARIO" == multiple ]]; then
                printf '{"items":[{"metadata":{"name":"l1-config","namespace":"one"}},{"metadata":{"name":"l1-config","namespace":"two"}}]}'
            else
                printf '{"items":[{"metadata":{"name":"l1-config","namespace":"fallback-l1"}}]}'
            fi
            return 0
            ;;
        *'-n storage-l1 get services -l app.kubernetes.io/name=l1-rpc -o json'*)
            printf '{"items":[{"metadata":{"name":"rpc-service","labels":{"app.kubernetes.io/instance":"rpc-release"}}}]}'
            return 0
            ;;
        *'-n storage-l1 get pvc -l app.kubernetes.io/name=l1-rpc,app.kubernetes.io/instance=rpc-release -o json'*)
            if [[ "$STORAGE_SCENARIO" == bound ]]; then
                printf '{"items":[{"spec":{"accessModes":["ReadWriteOnce"],"storageClassName":"managed-rwo"},"status":{"phase":"Bound"}}]}'
            else
                printf '{"items":[]}'
            fi
            return 0
            ;;
        *'auth can-i list storageclasses.storage.k8s.io'*) printf no; return 0 ;;
        *'-n storage-l1 get statefulsets -l app.kubernetes.io/name=l1-validator -o json'*)
            printf '{"items":[{"metadata":{"labels":{"app.kubernetes.io/instance":"validator-release"}}}]}'
            return 0
            ;;
        *'-n storage-l1 get configmap l1-config -o json'*)
            printf '{"data":{"RPC_RELEASE":"rpc-release","VALIDATOR_RELEASE":"validator-release"}}'
            return 0
            ;;
    esac
    return 1
}

discover_namespace
[[ "$NAMESPACE" == team-l1 ]]

DISCOVERY_SCENARIO=fallback
NAMESPACE=""
discover_namespace
[[ "$NAMESPACE" == fallback-l1 ]]

set +e
output="$(DISCOVERY_SCENARIO=denied NAMESPACE='' discover_namespace 2>&1)"
status=$?
set -e
[[ "$status" -eq 1 ]]
grep -Fq 'kubectl config set-context --current --namespace=<avalanche-l1-namespace>' <<<"$output"

set +e
output="$(DISCOVERY_SCENARIO=multiple NAMESPACE='' discover_namespace 2>&1)"
status=$?
set -e
[[ "$status" -eq 1 ]]
grep -Fq 'found 2 l1-config ConfigMaps' <<<"$output"

NAMESPACE=storage-l1
discover_workloads
[[ "$RPC_SERVICE" == rpc-service ]]
[[ "$STORAGE_CLASS" == managed-rwo ]]

set +e
output="$(STORAGE_SCENARIO=missing NAMESPACE=storage-l1 discover_workloads 2>&1)"
status=$?
set -e
[[ "$status" -eq 1 ]]
grep -Fq 'could not infer one bound ReadWriteOnce StorageClass' <<<"$output"

echo "Kubernetes Relayer namespace discovery smoke test passed"
