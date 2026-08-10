#!/usr/bin/env bash
# Static acceptance checks for the zero-input Terraform/Ansible Relayer flow.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VM_SCRIPT="scripts/l1/relayer.sh"
RELAYER_MODULE_DIR="scripts/l1/relayer"
DOCTOR_MODULE="$RELAYER_MODULE_DIR/doctor.sh"
INSTALLATION_MODULE="$RELAYER_MODULE_DIR/installation.sh"
MANAGEMENT_MODULE="$RELAYER_MODULE_DIR/management.sh"
AUTHORIZATION_MODULE="$RELAYER_MODULE_DIR/authorization.sh"
PREREQUISITES_MODULE="$RELAYER_MODULE_DIR/prerequisites.sh"
STATE_MODULE="$RELAYER_MODULE_DIR/state.sh"
RELAYER_SOURCES=("$VM_SCRIPT" "$RELAYER_MODULE_DIR"/*.sh)

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

for module in common doctor installation management authorization prerequisites state; do
    [[ -f "$RELAYER_MODULE_DIR/$module.sh" ]] || fail "Relayer $module module is missing"
    require_file_text "$VM_SCRIPT" "source \"\$ROOT_DIR/scripts/l1/relayer/$module.sh\""
done
[[ "$(wc -l <"$VM_SCRIPT")" -le 140 ]] || fail "Relayer dispatcher is no longer thin"
[[ "$(grep -Ec '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$VM_SCRIPT")" -eq 1 ]] || \
    fail "Relayer dispatcher defines operational functions instead of delegating to modules"

make -n relayer | grep -Fq './scripts/l1/relayer.sh install' || fail "make relayer does not use automatic discovery"
for target in \
    relayer-prereqs relayer-doctor relayer-prepare relayer-authorize relayer relayer-access relayer-status relayer-logs \
    relayer-backup relayer-upgrade relayer-remove; do
    make -n "$target" >/dev/null || fail "make $target is not dry-runnable"
done
make -n relayer-restore BACKUP=/tmp/relayer-20260716T120000.tar.gz >/dev/null || fail "VM restore target is not dry-runnable"

vm_help="$(make help-l1)"
all_help="$(make help-all)"
for command in relayer-prereqs relayer-doctor relayer-prepare relayer-authorize relayer relayer-access relayer-status relayer-logs relayer-backup relayer-restore relayer-upgrade relayer-remove; do
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

# The check above only knows today's two Relayer ports; this one holds for any
# port acp_relayer picks, which is how relayerd ended up on Safe's nginx port.
role_port_declarations="$(grep -rhE '^[a-z_]+_port:[[:space:]]*[0-9]+' ansible/roles --include='*.yml')"
for relayer_port in $(grep -hE '^acp_relayer_[a-z_]+_port:[[:space:]]*[0-9]+' ansible/roles/acp_relayer/defaults/main.yml | awk '{print $2}'); do
    other_claims="$(awk -v port="$relayer_port" '$2 == port && $1 !~ /^acp_relayer_/ {sub(/:$/, "", $1); print $1}' <<<"$role_port_declarations" | tr '\n' ' ')"
    [[ -z "$other_claims" ]] || fail "another Ansible role already claims Relayer host port $relayer_port: ${other_claims% }"
done
# Two roles on one host cannot share a port. Every collision exempted here
# predates the Relayer: 8080 is Safe's nginx redirect against the ICM Relayer
# API and 8001 Safe's Transaction Service against Graph Node's WebSocket, both
# on rpc[0]; 4000 is Blockscout against eRPC; 3000 and 9090 are Safe UI and the
# ICM Relayer metrics against the monitoring host. A new one must fail here.
known_shared_role_ports=' 3000 4000 8001 8080 9090 '
for shared_port in $(awk '{print $2}' <<<"$role_port_declarations" | sort | uniq -d); do
    [[ "$known_shared_role_ports" == *" $shared_port "* ]] || \
        fail "two Ansible roles declare host port $shared_port; give one of them a free port"
done
if ! grep -Fq -- '--api-listen-addr 127.0.0.1:8081' "$INSTALLATION_MODULE"; then
    fail "relayer.sh does not pin the daemon API to loopback port 8081"
fi
[[ "$(bash -c 'source scripts/l1/relayer.sh; managed_info_rpc_url fuji')" == "https://api.avax-test.network" ]] || \
    fail "Fuji does not select the managed Avalanche Info API"
[[ "$(bash -c 'source scripts/l1/relayer.sh; managed_info_rpc_url mainnet')" == "https://api.avax.network" ]] || \
    fail "Mainnet does not select the managed Avalanche Info API"
if grep -Fq -- '--info-rpc-url http://127.0.0.1:9650' "${RELAYER_SOURCES[@]}"; then
    fail "relayer.sh still uses the partial-sync local RPC for Primary bootstrap discovery"
fi
require_file_text ansible/playbooks/l1/discover-relayer.yml 'eligibleBootstrapPeerCount'
require_file_text ansible/playbooks/l1/discover-relayer.yml 'is-active'
require_file_text ansible/playbooks/l1/discover-relayer.yml 'safe.service'
require_file_text ansible/playbooks/l1/discover-relayer.yml 'http://127.0.0.1:8001/api/v1/about/'
require_file_text ansible/playbooks/l1/discover-relayer.yml 'safeConsoleEnvComplete'
require_file_text ansible/playbooks/l1/discover-relayer.yml 'SAFE_TX_SERVICE_URL'
require_file_text ansible/playbooks/l1/discover-relayer.yml 'SAFE_UI_URL'
require_file_text ansible/playbooks/l1/discover-relayer.yml 'SAFE_ADDRESS'
require_file_text ansible/playbooks/l1/discover-relayer.yml 'validatorPrivacy'
require_file_text ansible/playbooks/l1/discover-relayer.yml 'runtimeConfigFresh'
require_file_text ansible/playbooks/l1/discover-relayer.yml 'relayer-verify-identity.py'
require_file_text ansible/playbooks/l1/discover-relayer-authorization.yml 'relayer-verify-identity.py'
require_file_text ansible/playbooks/l1/files/relayer-verify-identity.py 'TLS certificate does not derive the recorded P2P NodeID'
require_file_text ansible/playbooks/l1/discover-relayer.yml 'rpcNodes'
require_file_text ansible/playbooks/l1/discover-relayer.yml 'missingValidatorPeers'
require_file_text ansible/playbooks/l1/discover-relayer.yml 'tlsIdentityExists'
require_file_text ansible/playbooks/l1/discover-relayer.yml 'p2pNodeId'
require_file_text ansible/playbooks/l1/stage-relayer-identity.yml 'identity-provisioned'
require_file_text ansible/playbooks/l1/stage-relayer-identity.yml 'not relayer_identity_files.results[0].stat.exists'
if grep -Fq "ansible_facts.services['safe.service'].state == 'running'" ansible/playbooks/l1/discover-relayer.yml; then
    fail "Safe discovery still rejects a healthy active (exited) oneshot unit"
fi
require_file_text ansible/roles/acp_relayer/tasks/main.yml 'systemctl is-failed --quiet relayerd.service'
require_file_text ansible/roles/acp_relayer/tasks/main.yml 'until: acp_relayer_ready.rc in [0, 42]'
require_file_text "$DOCTOR_MODULE" '/var/backups/relayerd/relayer.db.bak'
require_file_text "$DOCTOR_MODULE" 'the active daemon holds the live bbolt lock'
if grep -R -nE '127\.0\.0\.1:8080' "$VM_SCRIPT" "$RELAYER_MODULE_DIR" ansible/roles/acp_relayer \
    ansible/playbooks/l1/deploy-relayer.yml ansible/playbooks/l1/discover-relayer.yml \
    ansible/playbooks/l1/manage-relayer.yml ansible/playbooks/l1/restore-relayer.yml >/dev/null; then
    fail "a Relayer component still references port 8080, which Safe and the ICM Relayer occupy"
fi

require_file_text "$INSTALLATION_MODULE" 'Install the relayer and console on %s? [y/N] '
require_file_text "$INSTALLATION_MODULE" 'Console password (press Enter for none): '
require_file_text "$INSTALLATION_MODULE" 'Confirm console password: '
require_file_text "$INSTALLATION_MODULE" 'Console passwords did not match; try again.'
[[ "$(grep -Fc 'Install the relayer and console on %s? [y/N] ' "$INSTALLATION_MODULE")" -eq 1 ]] || fail "VM installer target prompt is not unique"
[[ "$(grep -Fc 'Console password (press Enter for none): ' "$INSTALLATION_MODULE")" -eq 1 ]] || fail "VM installer password prompt is not unique"
require_file_text "$DOCTOR_MODULE" 'doctor_vm'
require_file_text "$MANAGEMENT_MODULE" 'BACKUP must be an absolute path'
require_file_text "$MANAGEMENT_MODULE" 'unsupported link or special archive member'
require_file_text "$MANAGEMENT_MODULE" 'duplicate archive member'
require_file_text "$MANAGEMENT_MODULE" '"etc/relayerd/identity.json"'
require_file_text "$MANAGEMENT_MODULE" 'archived TLS certificate does not derive the archived P2P NodeID'
require_file_text "$MANAGEMENT_MODULE" 'backup manifest P2P NodeID does not match archived identity metadata'
require_file_text "$MANAGEMENT_MODULE" 'protocol_privacy_gate "$backup_node_id"'
require_file_text "$MANAGEMENT_MODULE" 'run_authorization_cleanup "$backup_node_id"'
require_file_text "$MANAGEMENT_MODULE" 'run_authorization_cleanup "$current_node_id"'
require_file_text ansible/playbooks/l1/restore-relayer.yml '/etc/relayerd/identity.json'
require_file_text ansible/playbooks/l1/restore-relayer.yml 'Bind staged restore identity to the admitted backup manifest'
require_file_text ansible/playbooks/l1/restore-relayer.yml 'restore_certificate.stat.checksum == restore_expected_tls_certificate_sha256'
require_file_text Makefile 'RELAYER_VERSION ?= official-latest'
require_file_text Makefile 'RELAYER_PRERELEASE_FALLBACK ?= v0.1.0-rc.8'
require_file_text "$VM_SCRIPT" 'ava-labs/avalanche-vmc-relayer'
require_file_text "$PREREQUISITES_MODULE" 'https://api.github.com/repos/$RELAYER_REPOSITORY/releases/tags/$RELAYER_VERSION'
require_file_text "$PREREQUISITES_MODULE" 'https://api.github.com/repos/$OFFICIAL_RELAYER_REPOSITORY/releases?per_page=100'
require_file_text "$PREREQUISITES_MODULE" 'Selected latest official production Relayer release:'
if grep -R -Fq 'ava-labs/validator-lifecycle-relayer' Makefile scripts/l1 docs/l1/RELAYER.md; then
    fail "active Terraform/Ansible Relayer integration still references the superseded repository name"
fi
if grep -Fq 'k8s-relayer' Makefile || [[ -e kubernetes/scripts/relayer.sh ]] || [[ -e kubernetes/helm/relayerd ]]; then
    fail "Terraform/Ansible PR contains Kubernetes Relayer entry points"
fi

# Extracts the body of a single Ansible task ("- name: ..." to the next task).
task_block() {
    local file="$1" name="$2"
    awk -v name="- name: $name" '
        $0 == name { found=1; next }
        found && /^- name: / { exit }
        found { print }
    ' "$file"
}

# Extracts the body of a bash function ("func() {" to its closing brace line).
function_body() {
    local file="$1" func="$2"
    awk -v marker="${func}() {" '
        $0 == marker { found=1 }
        found { print; if ($0 == "}") exit }
    ' "$file"
}

# A host that already runs Docker (e.g. via docker-ce for Safe) must never have
# its Docker package touched; the guard is a stat check gating the apt install.
acp_main="ansible/roles/acp_relayer/tasks/main.yml"
docker_stat_line="$(grep -Fn -- '- name: Check for an existing Docker installation' "$acp_main" | cut -d: -f1)"
docker_apt_line="$(grep -Fn -- '- name: Install Docker for the systemd-managed console container' "$acp_main" | cut -d: -f1)"
docker_enable_line="$(grep -Fn -- '- name: Enable Docker' "$acp_main" | cut -d: -f1)"
[[ -n "$docker_stat_line" && -n "$docker_apt_line" && -n "$docker_enable_line" ]] || \
    fail "$acp_main is missing one of the Docker install-guard tasks"
[[ "$docker_stat_line" -lt "$docker_apt_line" && "$docker_apt_line" -lt "$docker_enable_line" ]] || \
    fail "$acp_main does not order the Docker stat/apt/enable tasks stat -> apt -> enable"

docker_stat_block="$(task_block "$acp_main" 'Check for an existing Docker installation')"
grep -Fq 'ansible.builtin.stat' <<<"$docker_stat_block" || fail "Docker stat task no longer uses ansible.builtin.stat"
grep -Fq 'path: /usr/bin/docker' <<<"$docker_stat_block" || fail "Docker stat task no longer checks /usr/bin/docker"
grep -Fq 'register: acp_relayer_docker_stat' <<<"$docker_stat_block" || fail "Docker stat task no longer registers acp_relayer_docker_stat"
grep -Fq 'when:' <<<"$docker_stat_block" && fail "Docker stat task must be unconditional"

docker_apt_block="$(task_block "$acp_main" 'Install Docker for the systemd-managed console container')"
grep -Fq 'ansible.builtin.apt' <<<"$docker_apt_block" || fail "Docker install task no longer uses ansible.builtin.apt"
grep -Eq '^[[:space:]]*name:[[:space:]]*docker\.io[[:space:]]*$' <<<"$docker_apt_block" || \
    fail "Docker install task no longer installs the scalar package docker.io"
grep -Eq 'docker-ce|containerd\.io' <<<"$docker_apt_block" && \
    fail "Docker install task installs docker-ce/containerd.io, which would disrupt Safe's containers"
grep -Fq 'when: not acp_relayer_docker_stat.stat.exists' <<<"$docker_apt_block" || \
    fail "Docker install task no longer skips hosts with an existing Docker installation"

docker_enable_block="$(task_block "$acp_main" 'Enable Docker')"
grep -Fq 'ansible.builtin.systemd' <<<"$docker_enable_block" || fail "Enable Docker task no longer uses ansible.builtin.systemd"
grep -Fq 'name: docker' <<<"$docker_enable_block" || fail "Enable Docker task no longer targets the docker unit"
grep -q 'when:' <<<"$docker_enable_block" && \
    fail "Enable Docker task must run unconditionally regardless of which package provided docker.service"

# SSH host-key checking must stay off by default (matching ansible.cfg and the
# Terraform inventories); RELAYER_SSH_HOST_KEY_CHECKING is an opt-in override.
[[ "$(grep -Fc 'RELAYER_SSH_HOST_KEY_CHECKING:-no' "$STATE_MODULE")" -eq 1 ]] || \
    fail "relayer.sh's default host-key-checking value changed away from 'no'"
[[ "$(grep -Fc ':-accept-new' "$STATE_MODULE")" -eq 0 ]] || \
    fail "relayer.sh defaults SSH host-key checking to accept-new instead of matching ansible.cfg's no"
[[ "$(grep -Fc 'accept-new | yes | no | ask' "$STATE_MODULE")" -eq 1 ]] || \
    fail "relayer.sh's RELAYER_SSH_HOST_KEY_CHECKING whitelist no longer accepts accept-new/yes/ask as opt-in values"

# run_install must re-back-up existing Relayer state before reapplying over it,
# guarded by the keystore/release predicate, and only once, before prepare_release.
run_install_body="$(function_body "$INSTALLATION_MODULE" run_install)"
[[ -n "$run_install_body" ]] || fail "run_install function body could not be located in $INSTALLATION_MODULE"
[[ "$(grep -Fc "jq -r '.keystoreExists and .releaseMetadataExists'" <<<"$run_install_body")" -eq 1 ]] || \
    fail "run_install no longer guards the reapply backup with the keystore/release predicate"
[[ "$(grep -Fc 'run_manage_playbook backup' <<<"$run_install_body")" -eq 1 ]] || \
    fail "run_install must call run_manage_playbook backup exactly once when reapplying over existing state"
console_password_line="$(grep -Fn 'read_console_password console_password' <<<"$run_install_body" | head -1 | cut -d: -f1)"
keystore_check_line="$(grep -Fn "jq -r '.keystoreExists and .releaseMetadataExists'" <<<"$run_install_body" | cut -d: -f1)"
backup_call_line="$(grep -Fn 'run_manage_playbook backup' <<<"$run_install_body" | cut -d: -f1)"
prepare_release_line="$(grep -Fn 'prepare_release true' <<<"$run_install_body" | cut -d: -f1)"
[[ -n "$console_password_line" && -n "$keystore_check_line" && -n "$backup_call_line" && -n "$prepare_release_line" ]] || \
    fail "run_install is missing one of the console-password/backup-guard/prepare-release markers"
[[ "$console_password_line" -lt "$keystore_check_line" && "$keystore_check_line" -lt "$backup_call_line" && \
    "$backup_call_line" -lt "$prepare_release_line" ]] || \
    fail "run_install no longer backs up existing state after the console password prompt but before prepare_release"

identity_stage_line="$(grep -Fn 'stage_relayer_identity' <<<"$run_install_body" | head -1 | cut -d: -f1)"
privacy_gate_line="$(grep -Fn 'protocol_privacy_gate "$p2p_node_id"' <<<"$run_install_body" | tail -1 | cut -d: -f1)"
deploy_line="$(grep -Fn 'playbooks/l1/deploy-relayer.yml' <<<"$run_install_body" | cut -d: -f1)"
[[ -n "$identity_stage_line" && -n "$privacy_gate_line" && -n "$deploy_line" ]] || \
    fail "run_install is missing identity staging, the protocol-privacy gate, or runtime deployment"
[[ "$identity_stage_line" -lt "$privacy_gate_line" && "$privacy_gate_line" -lt "$deploy_line" ]] || \
    fail "run_install must stage the permanent identity, enforce protocol privacy, then install the runtime"
require_file_text "$INSTALLATION_MODULE" 'peer_visibility_gate "$DISCOVERY_FILE"'
require_file_text "$AUTHORIZATION_MODULE" 'complete effective allowlist'
require_file_text ansible/playbooks/l1/authorize-relayer.yml 'serial: 1'
require_file_text ansible/playbooks/l1/authorize-relayer.yml 'acp_relayer_stale_validator_ids'
require_file_text ansible/playbooks/l1/authorize-relayer.yml 'mode rollback'
require_file_text ansible/playbooks/l1/authorize-relayer.yml 'Wait for the L1 to recover on rpc[0]'
require_file_text ansible/playbooks/l1/authorize-relayer.yml 'Check the recovered validator L1'
require_file_text ansible/playbooks/l1/authorize-relayer.yml 'No later validator was changed.'
require_file_text ansible/playbooks/l1/discover-relayer.yml 'Inspect managed Relayer service definitions'
require_file_text ansible/playbooks/l1/discover-relayer.yml "'daemonInstalled': acp_relayer_service_units.results[0].stat.exists"

# The WalletConnect project ID default must stay non-degenerate, or the
# freshness-gate greps in ansible/roles/safe/tasks/main.yml become vacuous.
safe_defaults="ansible/roles/safe/defaults/main.yml"
wc_default="$(grep -E '^safe_walletconnect_project_id:' "$safe_defaults" | \
    sed -E 's/^safe_walletconnect_project_id:[[:space:]]*"?([0-9a-f]*)"?.*/\1/')"
[[ "$wc_default" =~ ^[0-9a-f]{32}$ ]] || \
    fail "$safe_defaults's safe_walletconnect_project_id default is not exactly 32 lowercase hex characters"
wc_first_char="${wc_default:0:1}"
[[ -n "${wc_default//$wc_first_char/}" ]] || \
    fail "$safe_defaults's safe_walletconnect_project_id default is a degenerate all-$wc_first_char run"

# The anchored form concatenates the CSS declaration with the raw Jinja value;
# real minified bundles never emit it verbatim, so it must not be reintroduced
# without a captured real emitted bundle proving otherwise.
if grep -Fq 'projectId:"{{ safe_walletconnect_project_id }}"' ansible/roles/safe/tasks/main.yml; then
    fail "ansible/roles/safe/tasks/main.yml reintroduced the anchored projectId literal"
fi

# Re-assert still-live invariants from earlier fixes so a later edit can't undo them.
require_file_text "$PREREQUISITES_MODULE" 'sub(/^\*/, "", file)'
require_file_text "$DOCTOR_MODULE" "jq -e '(.json // (.content | fromjson)) | .fundedFloat == true and .fundedGas == true'"
require_file_text "$DOCTOR_MODULE" 'RELAYER_LISTENERS_SCANNED'
require_file_text ansible/roles/acp_relayer/templates/relayerd.service.j2 'StartLimitIntervalSec=0'
require_file_text ansible/roles/acp_relayer/templates/relayerd.service.j2 'Restart=always'
require_file_text ansible/roles/acp_relayer/templates/relayer-console.service.j2 'Wants=relayerd.service'

echo "Relayer static acceptance checks passed"
