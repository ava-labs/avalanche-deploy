#!/usr/bin/env bash
# Static acceptance checks for the zero-input VM and Kubernetes Relayer flows.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
    echo "Relayer acceptance check failed: $*" >&2
    exit 1
}

require_file_text() {
    local file="$1" text="$2"
    grep -Fq "$text" "$file" || fail "$file does not contain: $text"
}

for cmd in grep helm make; do
    command -v "$cmd" >/dev/null 2>&1 || fail "$cmd not found in PATH"
done

[[ ! -e configs/services.yaml ]] || fail "concept-only configs/services.yaml still exists"
[[ ! -e scripts/l1/l1-up.sh ]] || fail "concept-only l1-up orchestrator still exists"

make -n relayer | grep -Fq './scripts/l1/relayer.sh install' || fail "make relayer does not use automatic discovery"
make -n k8s-relayer | grep -Fq './scripts/relayer.sh install' || fail "make k8s-relayer does not use automatic discovery"

if grep -Eq 'k8s-relayer-kms|relayer-setup|KEY_SOURCE|FLOAT_KEY|EVM_KEY|PCHAIN_KEY_ID|MANAGER_ADDR' Makefile; then
    fail "Makefile retains a manual-key, KMS, or manual-manager Relayer entry point"
fi

if grep -R -E 'from_port[[:space:]]*=[[:space:]]*(3080|8080)|to_port[[:space:]]*=[[:space:]]*(3080|8080)' terraform >/dev/null; then
    fail "Terraform exposes a Relayer or console port"
fi

require_file_text scripts/l1/relayer.sh 'Install the relayer and console on %s? [y/N] '
require_file_text scripts/l1/relayer.sh 'Console password (press Enter for none): '
require_file_text kubernetes/scripts/relayer.sh 'Install the relayer and console on %s? [y/N] '
require_file_text kubernetes/scripts/relayer.sh 'Console password (press Enter for none): '

rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT INT TERM
helm template relayer kubernetes/helm/relayerd \
    --set runtimeSecret.name=relayer-runtime \
    --set operatorIdentity=test-operator \
    --set l1.subnetId=test-subnet \
    --set l1.blockchainId=test-blockchain \
    --set l1.evmChainId=99999 \
    --set l1.chainName=test-chain \
    --set l1.managerAddress=0x1111111111111111111111111111111111111111 \
    --set l1.validatorManagerAddress=0x2222222222222222222222222222222222222222 \
    >"$rendered"

[[ "$(grep -c '^kind: StatefulSet$' "$rendered")" -eq 1 ]] || fail "chart must render exactly one StatefulSet"
[[ "$(grep -c '^kind: Service$' "$rendered" || true)" -eq 0 ]] || fail "chart rendered a Service"
[[ "$(grep -c '^kind: Ingress$' "$rendered" || true)" -eq 0 ]] || fail "chart rendered an Ingress"
[[ "$(grep -c '^kind: Secret$' "$rendered" || true)" -eq 0 ]] || fail "chart rendered or took ownership of runtime secrets"
require_file_text "$rendered" 'replicas: 1'
require_file_text "$rendered" 'name: relayerd'
require_file_text "$rendered" 'name: console'
require_file_text "$rendered" '"api-listen-addr": "127.0.0.1:8080"'
require_file_text "$rendered" 'ingress: []'
require_file_text "$rendered" 'resources: ["pods/portforward"]'

if helm template relayer kubernetes/helm/relayerd \
    --set replicas=2 \
    --set runtimeSecret.name=relayer-runtime \
    --set operatorIdentity=test-operator \
    --set l1.subnetId=test-subnet \
    --set l1.blockchainId=test-blockchain \
    --set l1.evmChainId=99999 \
    --set l1.chainName=test-chain \
    --set l1.managerAddress=0x1111111111111111111111111111111111111111 \
    --set l1.validatorManagerAddress=0x2222222222222222222222222222222222222222 \
    >/dev/null 2>&1; then
    fail "chart accepted more than one Relayer replica"
fi

echo "Relayer static acceptance checks passed"
