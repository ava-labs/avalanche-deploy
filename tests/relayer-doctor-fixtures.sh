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
    output="$(RELAYER_VERSION=v0.1.0-test RELAYER_DOCTOR_FIXTURE="$fixture" "$script" doctor 2>&1)"
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
run_case "$vm" bootstrap-peer-loss 1 FAIL VM.PEERS.BOOTSTRAP "no current Primary bootstrap peers are available"
run_case "$vm" manager-mismatch 1 FAIL VM.MANAGER.TOPOLOGY "manager topology differs"
run_case "$vm" unfunded 1 FAIL VM.FUNDING.READY "funding is below threshold"
run_case "$vm" partial-install 1 FAIL VM.INSTALLATION.STATE "installation is partial"
run_case "$vm" public-listeners 1 FAIL VM.LISTENERS.LOOPBACK "a listener is public"
run_case "$vm" stale-backup 0 WARN VM.BACKUPS.INTEGRITY "latest backup is stale"
run_case "$vm" corrupt-backup 1 FAIL VM.BACKUPS.INTEGRITY "latest backup is corrupt"
run_case "$vm" version-drift 1 FAIL VM.RELEASE.INTEGRITY "installed version has drifted"

safe_active_exited="$TMP_DIR/safe-active-exited.json"
cat >"$safe_active_exited" <<'EOF'
{
  "ownerType": "safe",
  "safeServicesDetected": true,
  "safeServiceState": "active",
  "safeServiceFactsState": "stopped",
  "safeTransactionServiceStatus": 200,
  "safeConsoleEnvPresent": false,
  "safeConsoleEnvComplete": false,
  "daemonInstalled": false,
  "consoleInstalled": false
}
EOF
safe_active_output="$(
    bash -c 'source "$1"; doctor_safe_integration "$2"; doctor_finish' _ "$vm" "$safe_active_exited"
)"
grep -Fq 'PASS VM.SAFE.DISCOVERY' <<<"$safe_active_output" || \
    fail "active (exited) Safe fixture was not accepted: $safe_active_output"

safe_missing_env="$TMP_DIR/safe-missing-console-env.json"
cat >"$safe_missing_env" <<'EOF'
{
  "ownerType": "safe",
  "safeServicesDetected": true,
  "safeServiceState": "active",
  "safeServiceFactsState": "stopped",
  "safeTransactionServiceStatus": 200,
  "safeConsoleEnvPresent": true,
  "safeConsoleEnvComplete": false,
  "daemonInstalled": true,
  "consoleInstalled": true
}
EOF
set +e
safe_missing_env_output="$(
    bash -c 'source "$1"; doctor_safe_integration "$2"; doctor_safe_console_environment "$2" operations; doctor_finish' \
        _ "$vm" "$safe_missing_env" 2>&1
)"
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "Safe missing-env fixture returned $status, expected 1: $safe_missing_env_output"
grep -Fq 'PASS VM.SAFE.DISCOVERY' <<<"$safe_missing_env_output" || \
    fail "Safe missing-env fixture did not preserve the healthy service result: $safe_missing_env_output"
grep -Fq 'FAIL VM.SAFE.CONSOLE_ENV' <<<"$safe_missing_env_output" || \
    fail "Safe missing-env fixture did not block operations: $safe_missing_env_output"

safe_missing_env_install_output="$(
    bash -c 'source "$1"; doctor_safe_console_environment "$2" install; doctor_finish' \
        _ "$vm" "$safe_missing_env" 2>&1
)"
grep -Fq 'WARN VM.SAFE.CONSOLE_ENV' <<<"$safe_missing_env_install_output" || \
    fail "install doctor did not mark repairable Safe env drift as a warning: $safe_missing_env_install_output"

safe_unhealthy="$TMP_DIR/safe-unhealthy.json"
cat >"$safe_unhealthy" <<'EOF'
{
  "ownerType": "safe",
  "safeServicesDetected": false,
  "safeServiceState": "inactive",
  "safeServiceFactsState": "stopped",
  "safeTransactionServiceStatus": 0
}
EOF
set +e
safe_unhealthy_output="$(
    bash -c 'source "$1"; doctor_safe_integration "$2"; doctor_finish' _ "$vm" "$safe_unhealthy" 2>&1
)"
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "unhealthy Safe fixture returned $status, expected 1: $safe_unhealthy_output"
grep -Fq 'FAIL VM.SAFE.DISCOVERY' <<<"$safe_unhealthy_output" || \
    fail "unhealthy Safe fixture did not produce a blocker: $safe_unhealthy_output"

run_state_case() {
    local name="$1" runtime_ready="$2" expected_level="$3" expected_summary="$4"
    local output status
    set +e
    output="$(
        STATE_CASE="$name" bash -c '
            source "$1"
            relayer_remote_check() {
                case "$STATE_CASE:$*" in
                    ready-valid:*"/usr/bin/test -f /var/backups/relayerd/relayer.db.bak"*) return 0 ;;
                    ready-valid:*"/usr/local/bin/relayer-restore --check-db /var/backups/relayerd/relayer.db.bak"*) return 0 ;;
                    ready-no-backup:*"/usr/bin/test -f /var/backups/relayerd/relayer.db.bak"*) return 1 ;;
                    active-not-ready:*"/usr/bin/systemctl is-active --quiet relayerd.service"*) return 0 ;;
                    stopped-live:*"/usr/bin/systemctl is-active --quiet relayerd.service"*) return 1 ;;
                    stopped-live:*"/usr/local/bin/relayer-restore --check-db /var/lib/relayerd/relayer.db"*) return 0 ;;
                    *) return 1 ;;
                esac
            }
            doctor_state_integrity "$2" mock-ansible
            doctor_finish
        ' _ "$vm" "$runtime_ready" 2>&1
    )"
    status=$?
    set -e
    if [[ "$expected_level" == FAIL ]]; then
        [[ "$status" -eq 1 ]] || fail "$name state fixture returned $status, expected 1: $output"
    else
        [[ "$status" -eq 0 ]] || fail "$name state fixture returned $status, expected 0: $output"
    fi
    grep -Fq "$expected_level VM.STATE.INTEGRITY | $expected_summary" <<<"$output" || \
        fail "$name state fixture produced the wrong result: $output"
}

run_state_case ready-valid true PASS "the daemon-opened bbolt state has a structurally valid rolling hot backup"
run_state_case ready-no-backup true WARN "relayerd opened the live database but its first rolling hot backup is not available yet"
run_state_case active-not-ready false WARN "the active daemon holds the live bbolt lock and is not ready enough to verify its rolling backup"
run_state_case stopped-live false PASS "offline bbolt state passes a read-only integrity check"

password_result="$(
    printf '\n' |
        bash -c 'source "$1"; password=sentinel; read_console_password password; printf "%s" "$password"' _ "$vm" 2>/dev/null
)"
[[ -z "$password_result" ]] || fail "empty console password was not accepted"

password_result="$(
    printf 'correct horse\ncorrect horse\n' |
        bash -c 'source "$1"; password=; read_console_password password; printf "%s" "$password"' _ "$vm" 2>/dev/null
)"
[[ "$password_result" == 'correct horse' ]] || fail "matching console password was not returned"

password_stderr="$TMP_DIR/password-mismatch.stderr"
password_result="$(
    printf 'first\nwrong\nsecond\nsecond\n' |
        bash -c 'source "$1"; password=; read_console_password password; printf "%s" "$password"' _ "$vm" 2>"$password_stderr"
)"
[[ "$password_result" == second ]] || fail "password retry did not return the matching value"
grep -Fq 'Console passwords did not match; try again.' "$password_stderr" || \
    fail "password mismatch did not print a non-secret retry message"
if grep -Eq 'first|wrong|second' "$password_stderr"; then
    fail "password prompt output exposed a password value"
fi

set +e
printf 'interrupted\n' |
    bash -c 'source "$1"; password=; read_console_password password' _ "$vm" >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "interrupted password confirmation unexpectedly succeeded"

set +e
sentinel_output="$("$vm" doctor 2>&1)"
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "sentinel doctor returned $status, expected 1: $sentinel_output"
grep -Fq 'production Relayer pin is awaiting repository transfer' <<<"$sentinel_output" || \
    fail "sentinel doctor did not explain the prerelease override"

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
