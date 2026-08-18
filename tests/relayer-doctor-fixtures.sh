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
doctor_module="$ROOT_DIR/scripts/l1/relayer/doctor.sh"

# The RELAYER_DOCTOR_FIXTURE short-circuit in doctor_vm proves only the shared
# result formatter and the doctor_finish exit-code contract; every check below
# calls the real doctor functions.
run_case "$vm" formatter-pass 0 PASS VM.RUNTIME.READY "installed runtime is ready"
run_case "$vm" formatter-blocker 1 FAIL VM.FUNDING.READY "funding is below threshold"

# doctor_command derives its check ID from the command name it probes.
set +e
tool_output="$(
    bash -c 'source "$1"; doctor_command bash Bash; doctor_command relayer-absent-tool OpenSSH; doctor_finish' _ "$vm" 2>&1
)"
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "a missing required tool did not block: $tool_output"
grep -Fq 'PASS VM.TOOL.BASH | bash is available' <<<"$tool_output" || \
    fail "an installed tool was not reported as available: $tool_output"
grep -Fq 'FAIL VM.TOOL.RELAYER_ABSENT_TOOL | relayer-absent-tool is missing | remediation: run make relayer-prereqs or install OpenSSH' <<<"$tool_output" || \
    fail "a missing tool did not produce its derived check ID and remediation: $tool_output"

pipe_output="$(
    bash -c 'source "$1"; doctor_result WARN VM.L1_ENV.AGE "sum|mary" "reme|diation"' _ "$vm"
)"
[[ "$pipe_output" == 'WARN VM.L1_ENV.AGE | sum/mary | remediation: reme/diation' ]] || \
    fail "a result carrying the field separator was not sanitised: $pipe_output"

set +e
scope_output="$(bash -c 'source "$1"; doctor_vm bogus-scope' _ "$vm" 2>&1)"
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "an unsupported doctor scope returned $status, expected 1: $scope_output"
grep -Fq "unsupported Relayer doctor scope 'bogus-scope'" <<<"$scope_output" || \
    fail "an unsupported doctor scope did not name the rejected scope: $scope_output"

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

privacy_node_id="NodeID-DoctorPrivacyFixture"
write_privacy_fixture() {
    local path="$1" first_private="$2" second_private="$3" identity_exists="$4"
    local first_allowed="$5" second_allowed="$6"
    jq -n \
        --arg node_id "$privacy_node_id" \
        --argjson first_private "$first_private" \
        --argjson second_private "$second_private" \
        --arg rpc_node_id "NodeID-RpcDoctorFixture" \
        --argjson identity_exists "$identity_exists" \
        --argjson first_allowed "$first_allowed" \
        --argjson second_allowed "$second_allowed" \
        '{
          tlsIdentityExists: $identity_exists,
          p2pNodeId: (if $identity_exists then $node_id else "" end),
          rpcNodes: [{name: "rpc-archive-1", nodeId: $rpc_node_id}],
          validatorPrivacy: [
            {
              name: "validator-1",
              validatorOnly: $first_private,
              allowedNodes: (if $first_allowed then [$node_id, $rpc_node_id] else [] end),
              runtimeConfigFresh: true
            },
            {
              name: "validator-2",
              validatorOnly: $second_private,
              allowedNodes: (if $second_allowed then [$node_id, $rpc_node_id] else [] end),
              runtimeConfigFresh: true
            }
          ]
        }' >"$path"
}

run_privacy_doctor_case() {
    local name="$1" expected_exit="$2" expected_level="$3" expected_summary="$4"
    local fixture="$5" output status
    set +e
    output="$(bash -c 'source "$1"; doctor_protocol_privacy "$2"; doctor_finish' _ "$vm" "$fixture" 2>&1)"
    status=$?
    set -e
    [[ "$status" -eq "$expected_exit" ]] || \
        fail "$name privacy fixture returned $status, expected $expected_exit: $output"
    grep -Fq "$expected_level VM.PROTOCOL.PRIVACY | $expected_summary" <<<"$output" || \
        fail "$name privacy fixture produced the wrong result: $output"
}

privacy_open="$TMP_DIR/privacy-open.json"
privacy_unstaged="$TMP_DIR/privacy-unstaged.json"
privacy_allowed="$TMP_DIR/privacy-allowed.json"
privacy_rpc_missing="$TMP_DIR/privacy-rpc-missing.json"
privacy_stale="$TMP_DIR/privacy-stale.json"
privacy_missing="$TMP_DIR/privacy-missing.json"
privacy_mixed="$TMP_DIR/privacy-mixed.json"
write_privacy_fixture "$privacy_open" false false false false false
write_privacy_fixture "$privacy_unstaged" true true false false false
write_privacy_fixture "$privacy_allowed" true true true true true
jq --arg node_id "$privacy_node_id" \
    '.validatorPrivacy[].allowedNodes = [$node_id]' \
    "$privacy_allowed" >"$privacy_rpc_missing"
jq '.validatorPrivacy[1].runtimeConfigFresh = false' \
    "$privacy_allowed" >"$privacy_stale"
write_privacy_fixture "$privacy_missing" true true true true false
write_privacy_fixture "$privacy_mixed" true false true true false

run_privacy_doctor_case open 0 PASS \
    'validatorOnly is disabled on all 2 validator(s); a NodeID allowlist is not required' "$privacy_open"
run_privacy_doctor_case unstaged 0 WARN \
    'all validators enforce protocol privacy; the permanent Relayer NodeID has not been staged yet' "$privacy_unstaged"
run_privacy_doctor_case allowed 0 PASS \
    'all 2 protocol-private validator(s) loaded allowlists for the permanent Relayer and managed RPC NodeIDs' "$privacy_allowed"
run_privacy_doctor_case stale 1 FAIL \
    'protocol-private configuration is newer than the running AvalancheGo process on: validator-2' "$privacy_stale"
run_privacy_doctor_case rpc-missing 1 FAIL \
    'managed RPC NodeIDs are absent from protocol-private validator allowlists' "$privacy_rpc_missing"
run_privacy_doctor_case missing 1 FAIL \
    "$privacy_node_id is absent from allowedNodes on: validator-2" "$privacy_missing"
run_privacy_doctor_case mixed 1 FAIL \
    'validatorOnly is inconsistent across the L1 validator set (1 of 2 enabled)' "$privacy_mixed"

peer_visibility_fixture="$TMP_DIR/peer-visibility.json"
jq -n '{
  tlsIdentityExists: false,
  missingValidatorPeers: [{name: "validator-1", nodeId: "NodeID-Validator1"}],
  validatorPrivacy: [
    {name: "validator-1", validatorOnly: true},
    {name: "validator-2", validatorOnly: true}
  ]
}' >"$peer_visibility_fixture"
peer_visibility_output="$(bash -c '
  source "$1"
  doctor_peer_visibility "$2" install
  doctor_finish
' _ "$vm" "$peer_visibility_fixture" 2>&1)"
grep -Fq 'WARN VM.PEERS.VISIBLE | protocol-private validators are not visible to rpc[0]' \
  <<<"$peer_visibility_output" || fail "install peer-visibility fixture did not permit identity staging: $peer_visibility_output"
set +e
peer_visibility_output="$(bash -c '
  source "$1"
  doctor_peer_visibility "$2" operations
  doctor_finish
' _ "$vm" "$peer_visibility_fixture" 2>&1)"
peer_visibility_status=$?
set -e
[[ "$peer_visibility_status" -eq 1 ]] || \
  fail "operations peer-visibility fixture returned $peer_visibility_status, expected 1: $peer_visibility_output"
grep -Fq 'FAIL VM.PEERS.VISIBLE | rpc[0] cannot see deployed validator peers' \
  <<<"$peer_visibility_output" || fail "operations peer-visibility fixture did not block: $peer_visibility_output"

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
                    ready-corrupt-backup:*"/usr/bin/test -f /var/backups/relayerd/relayer.db.bak"*) return 0 ;;
                    ready-corrupt-backup:*"/usr/local/bin/relayer-restore --check-db /var/backups/relayerd/relayer.db.bak"*) return 1 ;;
                    ready-no-backup:*"/usr/bin/test -f /var/backups/relayerd/relayer.db.bak"*) return 1 ;;
                    active-not-ready:*"/usr/bin/systemctl is-active --quiet relayerd.service"*) return 0 ;;
                    stopped-live:*"/usr/bin/systemctl is-active --quiet relayerd.service"*) return 1 ;;
                    stopped-live:*"/usr/local/bin/relayer-restore --check-db /var/lib/relayerd/relayer.db"*) return 0 ;;
                    offline-corrupt:*"/usr/bin/systemctl is-active --quiet relayerd.service"*) return 1 ;;
                    offline-corrupt:*"/usr/local/bin/relayer-restore --check-db /var/lib/relayerd/relayer.db"*) return 1 ;;
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
run_state_case ready-corrupt-backup true FAIL "the rolling bbolt hot backup failed its read-only integrity check"
run_state_case ready-no-backup true WARN "relayerd opened the live database but its first rolling hot backup is not available yet"
run_state_case active-not-ready false WARN "the active daemon holds the live bbolt lock and is not ready enough to verify its rolling backup"
run_state_case stopped-live false PASS "offline bbolt state passes a read-only integrity check"
run_state_case offline-corrupt false FAIL "bbolt state integrity check failed"

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

default_source="$(bash -c 'source "$1"; printf "%s|%s|%s" "$RELAYER_REPOSITORY" "$RELAYER_VERSION" "$RELAYER_PRERELEASE_FALLBACK"' _ "$vm")"
[[ "$default_source" == 'ava-labs/avalanche-vmc-relayer|official-latest|v0.1.0-rc.8' ]] || \
    fail "default release source is not the official stable selector with the reviewed rc.8 fallback: $default_source"

stable_selection="$(bash -c '
    source "$1"
    release_curl() {
        printf "%s\n" '\''[
          {"draft":false,"prerelease":true,"tag_name":"v0.2.0-rc.1"},
          {"draft":false,"prerelease":false,"tag_name":"v0.1.0"}
        ]'\''
    }
    resolve_release_version
    printf "%s" "$RELAYER_VERSION"
' _ "$vm" 2>/dev/null)"
[[ "$stable_selection" == v0.1.0 ]] || \
    fail "official stable release selector returned $stable_selection instead of v0.1.0"

fallback_selection="$(bash -c '
    source "$1"
    release_curl() { printf "[]\n"; }
    resolve_release_version
    printf "%s" "$RELAYER_VERSION"
' _ "$vm" 2>/dev/null)"
[[ "$fallback_selection" == v0.1.0-rc.8 ]] || \
    fail "unavailable stable release did not select the reviewed rc.8 fallback: $fallback_selection"

set +e
release_query_failure="$(bash -c '
    source "$1"
    release_curl() { return 1; }
    resolve_release_version
' _ "$vm" 2>&1)"
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "failed official release query returned $status, expected 1"
grep -Fq 'could not query official Relayer releases' <<<"$release_query_failure" || \
    fail "failed official release query silently used the prerelease fallback"
set +e
source_override_output="$(RELAYER_DEVELOPMENT_REPOSITORY=anishnar/validator-lifecycle-relayer \
    bash -c 'source "$1"; validate_release_source' _ "$vm" 2>&1)"
status=$?
set -e
[[ "$status" -eq 1 ]] || fail "unapproved repository override returned $status, expected 1"
grep -Fq 'repository or authentication overrides require RELAYER_DEVELOPMENT=true' <<<"$source_override_output" || \
    fail "unapproved repository override did not explain the development gate"
RELAYER_DEVELOPMENT=true RELAYER_DEVELOPMENT_REPOSITORY=anishnar/validator-lifecycle-relayer \
    bash -c 'source "$1"; validate_release_source' _ "$vm"

private_asset="$TMP_DIR/private-release-asset"
bash -c '
    source "$1"
    RELAYER_REPOSITORY=ava-labs/avalanche-vmc-relayer
    RELAYER_VERSION=v0.1.0-rc.8
    RELAYER_DEVELOPMENT_TOKEN=fixture-token
    release_curl() {
        if [[ "$*" == *"/releases/tags/"* ]]; then
            printf "%s\n" '\''{"assets":[{"name":"checksums.txt","url":"https://api.github.com/repos/ava-labs/avalanche-vmc-relayer/releases/assets/123"}]}'\''
            return
        fi
        local destination="" previous=""
        for argument in "$@"; do
            if [[ "$previous" == -o ]]; then destination="$argument"; fi
            previous="$argument"
        done
        [[ -n "$destination" ]] || return 1
        printf "private-release-asset\n" >"$destination"
    }
    download_release_asset checksums.txt "$2"
' _ "$vm" "$private_asset"
[[ "$(cat "$private_asset")" == private-release-asset ]] || \
    fail "authenticated private-release API path did not download the selected asset"

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

# The suite can only call the doctor functions it can source, so pin the whole
# diagnostic surface: a renamed, deleted, or untested check ID fails here.
expected_ids=(
    VM.ACCESS.SSH VM.ACCESS.SUDO VM.BACKUPS.INTEGRITY VM.CONFIG.BOOTSTRAP
    VM.FUNDING.READY VM.INSTALLATION.STATE VM.INVENTORY.MATCH VM.KEYS.INTEGRITY
    VM.L1_ENV.AGE VM.L1_ENV.METADATA VM.L1_ENV.PRESENT VM.LISTENERS.LOOPBACK
    VM.MANAGER.TOPOLOGY VM.PEERS.BOOTSTRAP VM.PEERS.VISIBLE VM.PREFLIGHT.REMOTE
    VM.PROTOCOL.PRIVACY
    VM.RELEASE.AVAILABLE VM.RELEASE.INTEGRITY VM.RPC.HEALTH VM.RUNTIME.READY
    VM.SAFE.CONSOLE_ENV VM.SAFE.DISCOVERY VM.STATE.INTEGRITY VM.TARGET.ARCHITECTURE
    VM.TARGET.CAPACITY VM.TERRAFORM.STATE VM.TOOL.TERRAFORM_VERSION
)
for id in "${expected_ids[@]}"; do
    grep -Fq "$id" "$doctor_module" || fail "$doctor_module no longer emits the $id diagnostic"
done
for id in $(grep -oE 'VM\.[A-Z0-9_]+\.[A-Z0-9_]+' "$doctor_module" | sort -u); do
    [[ " ${expected_ids[*]} " == *" $id "* ]] || fail "$doctor_module emits $id, which this suite does not cover"
done
for tool in terraform ansible ansible-playbook ansible-inventory jq python3 curl ssh; do
    grep -Fq "doctor_command $tool " "$doctor_module" || fail "the doctor no longer requires $tool"
done

# ssh_target must default to StrictHostKeyChecking=no (matching ansible.cfg and
# the Terraform inventories) and honour RELAYER_SSH_HOST_KEY_CHECKING as an
# opt-in override, for both remote-access actions that build an ssh argv.
ssh_stub_dir="$TMP_DIR/ssh-stub"
mkdir -p "$ssh_stub_dir"
cat >"$ssh_stub_dir/ssh" <<'EOF'
#!/bin/sh
printf '%s ' "$@"
printf '\n'
EOF
chmod +x "$ssh_stub_dir/ssh"

ssh_inventory_summary="$TMP_DIR/ssh-inventory-summary.json"
cat >"$ssh_inventory_summary" <<'EOF'
{"rpc":[{"user":"ubuntu","port":22,"privateKeyFile":""}]}
EOF

ssh_argv="$(
    PATH="$ssh_stub_dir:$PATH" bash -c '
        source "$1"
        ACTION=logs
        TARGET_HOST=rpc0.example.test
        INVENTORY_SUMMARY="$2"
        ssh_target
    ' _ "$vm" "$ssh_inventory_summary"
)"
grep -Fq -- '-o StrictHostKeyChecking=no' <<<"$ssh_argv" || \
    fail "ssh_target did not default RELAYER_SSH_HOST_KEY_CHECKING to no: $ssh_argv"

ssh_argv_override="$(
    PATH="$ssh_stub_dir:$PATH" RELAYER_SSH_HOST_KEY_CHECKING=accept-new bash -c '
        source "$1"
        ACTION=logs
        TARGET_HOST=rpc0.example.test
        INVENTORY_SUMMARY="$2"
        ssh_target
    ' _ "$vm" "$ssh_inventory_summary"
)"
grep -Fq -- '-o StrictHostKeyChecking=accept-new' <<<"$ssh_argv_override" || \
    fail "ssh_target did not honour RELAYER_SSH_HOST_KEY_CHECKING=accept-new as an override: $ssh_argv_override"

# run_install's reapply-backup guard, `jq -r '.keystoreExists and .releaseMetadataExists'`,
# must fail closed (report "false") on partial discovery state so a fresh or
# half-populated install never triggers an extra backup playbook run.
backup_guard='.keystoreExists and .releaseMetadataExists'
[[ "$(jq -r "$backup_guard" <<<'{"keystoreExists": true, "releaseMetadataExists": true}')" == true ]] || \
    fail "the reapply-backup guard did not fire when both keystore and release metadata exist"
[[ "$(jq -r "$backup_guard" <<<'{"keystoreExists": true}')" == false ]] || \
    fail "the reapply-backup guard did not fail closed when releaseMetadataExists is missing"
[[ "$(jq -r "$backup_guard" <<<'{"releaseMetadataExists": true}')" == false ]] || \
    fail "the reapply-backup guard did not fail closed when keystoreExists is missing"
[[ "$(jq -r "$backup_guard" <<<'{"keystoreExists": true, "releaseMetadataExists": false}')" == false ]] || \
    fail "the reapply-backup guard did not fail closed when releaseMetadataExists is false"
[[ "$(jq -r "$backup_guard" <<<'{}')" == false ]] || \
    fail "the reapply-backup guard did not fail closed on a discovery file missing both fields"

echo "Relayer doctor fixtures passed"
