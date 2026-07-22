#!/usr/bin/env bash
# Stable diagnostic result and exit-code fixtures for the managed VM Relayer doctor.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/relayer-doctor-fixtures.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

fail() {
    echo "Relayer doctor fixture failed: $*" >&2
    exit 1
}

run_case() {
    local script="$1" name="$2" expected_exit="$3" level="$4" id="$5" summary="$6"
    local fixture="$TMP_DIR/$name.fixture" output status
    printf '%s|%s|%s|%s\n' "$level" "$id" "$summary" "fixture remediation for $name" >"$fixture"
    set +e
    output="$(RELAYER_DOCTOR_FIXTURE="$fixture" "$script" doctor 2>&1)"
    status=$?
    set -e
    [[ "$status" -eq "$expected_exit" ]] || fail "$name returned $status, expected $expected_exit: $output"
    grep -Fq "$level $id | $summary | remediation: fixture remediation for $name" <<<"$output" || \
        fail "$name did not preserve its stable level/id/remediation: $output"
}

vm="$ROOT_DIR/scripts/l1/relayer.sh"

run_case "$vm" healthy-preinstall 0 PASS VM.INSTALLATION.STATE "ready for a fresh install"
run_case "$vm" healthy-installed 0 PASS VM.RUNTIME.READY "installed runtime is ready"
run_case "$vm" missing-tools 1 FAIL VM.TOOL.TERRAFORM "Terraform is missing"
run_case "$vm" old-terraform 1 FAIL VM.TOOL.TERRAFORM_VERSION "Terraform version is too old"
run_case "$vm" absent-l1-env 1 FAIL VM.L1_ENV.PRESENT "l1.env is absent"
run_case "$vm" stale-l1-env 0 WARN VM.L1_ENV.AGE "l1.env is stale"
run_case "$vm" multiple-states 1 FAIL VM.TERRAFORM.STATE "multiple states are active"
run_case "$vm" inventory-drift 1 FAIL VM.INVENTORY.MATCH "inventory differs from Terraform"
run_case "$vm" ssh-denial 1 FAIL VM.ACCESS.SSH "SSH is denied"
run_case "$vm" sudo-denial 1 FAIL VM.ACCESS.SUDO "sudo is denied"
run_case "$vm" unavailable-rpc 1 FAIL VM.RPC.HEALTH "RPC is unavailable"
run_case "$vm" peer-loss 1 FAIL VM.PEERS.VISIBLE "validator peers are missing"
run_case "$vm" manager-mismatch 1 FAIL VM.MANAGER.TOPOLOGY "manager topology differs"
run_case "$vm" unfunded 1 FAIL VM.FUNDING.READY "funding is below threshold"
run_case "$vm" partial-install 1 FAIL VM.INSTALLATION.STATE "installation is partial"
run_case "$vm" public-listeners 1 FAIL VM.LISTENERS.LOOPBACK "a listener is public"
run_case "$vm" stale-backup 0 WARN VM.BACKUPS.INTEGRITY "latest backup is stale"
run_case "$vm" corrupt-backup 1 FAIL VM.BACKUPS.INTEGRITY "latest backup is corrupt"
run_case "$vm" version-drift 1 FAIL VM.RELEASE.INTEGRITY "installed version has drifted"

set +e
"$vm" invalid-action >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "invalid action for $vm returned $status, expected usage status 2"

set +e
RELAYER_VERSION=not-a-release "$vm" doctor >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "invalid version for $vm returned $status, expected usage status 2"

echo "Relayer doctor fixtures passed"
