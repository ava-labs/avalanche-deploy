#!/usr/bin/env bash
# Static acceptance checks for the zero-input Terraform/Ansible Relayer flow.
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

for cmd in grep make; do
    command -v "$cmd" >/dev/null 2>&1 || fail "$cmd not found in PATH"
done

[[ ! -e configs/services.yaml ]] || fail "concept-only configs/services.yaml still exists"
[[ ! -e scripts/l1/l1-up.sh ]] || fail "concept-only l1-up orchestrator still exists"

make -n relayer | grep -Fq './scripts/l1/relayer.sh install' || fail "make relayer does not use automatic discovery"
for target in \
    relayer-prereqs relayer-doctor relayer relayer-access relayer-status relayer-logs \
    relayer-backup relayer-upgrade relayer-remove; do
    make -n "$target" >/dev/null || fail "make $target is not dry-runnable"
done
make -n relayer-restore BACKUP=/tmp/relayer-20260716T120000.tar.gz >/dev/null || fail "VM restore target is not dry-runnable"

vm_help="$(make help-l1)"
all_help="$(make help-all)"
for command in relayer-prereqs relayer-doctor relayer relayer-access relayer-status relayer-logs relayer-backup relayer-restore relayer-upgrade relayer-remove; do
    grep -Fq "make $command" <<<"$vm_help" || fail "help-l1 omits $command"
    grep -Fq "make $command" <<<"$all_help" || fail "help-all omits $command"
done
if grep -Eq 'k8s-relayer-kms|relayer-setup|KEY_SOURCE|FLOAT_KEY|EVM_KEY|PCHAIN_KEY_ID|MANAGER_ADDR' Makefile; then
    fail "Makefile retains a manual-key, KMS, or manual-manager Relayer entry point"
fi

# 8080 stays banned even though relayerd moved to 8081: Safe's nginx redirect and
# the ICM Relayer's host-network API both bind it on rpc[0] and must never be exposed.
if grep -R -E 'from_port[[:space:]]*=[[:space:]]*(3080|8080|8081)|to_port[[:space:]]*=[[:space:]]*(3080|8080|8081)' terraform >/dev/null; then
    fail "Terraform exposes a Relayer or console port"
fi

# The Relayer co-locates with Safe (nginx on 8080/443/4443) and the ICM Relayer
# (host-network API on 8080) on rpc[0]; its ports must stay unclaimed elsewhere.
if grep -R -E '_port:[[:space:]]*"?(8081|3080)"?([[:space:]]|#|$)' ansible/roles --include='*.yml' | grep -v 'ansible/roles/acp_relayer/' >/dev/null; then
    fail "another Ansible role claims Relayer port 8081 or console port 3080"
fi
if ! grep -Fq -- '--api-listen-addr 127.0.0.1:8081' scripts/l1/relayer.sh; then
    fail "relayer.sh does not pin the daemon API to loopback port 8081"
fi
if grep -R -nE '127\.0\.0\.1:8080' scripts/l1/relayer.sh ansible/roles/acp_relayer \
    ansible/playbooks/l1/deploy-relayer.yml ansible/playbooks/l1/discover-relayer.yml \
    ansible/playbooks/l1/manage-relayer.yml ansible/playbooks/l1/restore-relayer.yml >/dev/null; then
    fail "a Relayer component still references port 8080, which Safe and the ICM Relayer occupy"
fi

require_file_text scripts/l1/relayer.sh 'Install the relayer and console on %s? [y/N] '
require_file_text scripts/l1/relayer.sh 'Console password (press Enter for none): '
[[ "$(grep -Fc 'Install the relayer and console on %s? [y/N] ' scripts/l1/relayer.sh)" -eq 1 ]] || fail "VM installer target prompt is not unique"
[[ "$(grep -Fc 'Console password (press Enter for none): ' scripts/l1/relayer.sh)" -eq 1 ]] || fail "VM installer password prompt is not unique"
require_file_text scripts/l1/relayer.sh 'doctor_vm'
require_file_text scripts/l1/relayer.sh 'BACKUP must be an absolute path'
require_file_text scripts/l1/relayer.sh 'unsupported link or special archive member'
require_file_text Makefile 'v0.0.0-transfer-required'
require_file_text scripts/l1/relayer.sh 'ava-labs/validator-lifecycle-relayer'
if grep -Fq 'k8s-relayer' Makefile || [[ -e kubernetes/scripts/relayer.sh ]] || [[ -e kubernetes/helm/relayerd ]]; then
    fail "Terraform/Ansible PR contains Kubernetes Relayer entry points"
fi

echo "Relayer static acceptance checks passed"
