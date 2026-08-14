#!/usr/bin/env bash
# Static acceptance checks for the zero-input Relayer flow on both supported
# paths: the Terraform/Ansible (VM) path and the Kubernetes path. The VM
# assertions run first, the Kubernetes assertions after the shared helpers.
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

K8S_SCRIPT="kubernetes/scripts/relayer.sh"
K8S_CHART="kubernetes/helm/relayerd"
K8S_VALUES="$K8S_CHART/values.yaml"
# Every harness the Kubernetes path is gated by. The doctor fixtures belong here
# too: without them the 900-line suite could be deleted with every gate still green.
K8S_SMOKE_TESTS=(
    tests/relayer-k8s-doctor-fixtures.sh
    tests/relayer-k8s-discovery-smoke.sh
    tests/relayer-k8s-restore-smoke.sh
)
# The ten supported Kubernetes operator entry points.
K8S_COMMANDS=(
    k8s-relayer-prereqs k8s-relayer-doctor k8s-relayer k8s-relayer-access k8s-relayer-status
    k8s-relayer-logs k8s-relayer-backup k8s-relayer-restore k8s-relayer-upgrade k8s-relayer-remove
)

fail() {
    echo "Relayer acceptance check failed: $*" >&2
    exit 1
}

require_file_text() {
    local file="$1" text="$2"
    grep -Fq "$text" "$file" || fail "$file does not contain: $text"
}

# helm and jq are needed by the Kubernetes assertions below: the chart is rendered
# and asserted on, and the k8s driver parses every cluster response with jq.
for cmd in grep make helm jq; do
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
# This branch is the Kubernetes Relayer change stacked on top of the
# Terraform/Ansible one, so the Kubernetes entry points are now required rather
# than banned. Everything in the Kubernetes section at the bottom of this file
# depends on all four of these existing.
grep -Fq 'k8s-relayer' Makefile || fail "Makefile is missing the Kubernetes Relayer entry points"
[[ -f "$K8S_SCRIPT" ]] || fail "the Kubernetes Relayer lifecycle driver $K8S_SCRIPT is missing"
[[ -d "$K8S_CHART" ]] || fail "the Kubernetes Relayer chart $K8S_CHART is missing"
for k8s_test in "${K8S_SMOKE_TESTS[@]}"; do
    [[ -f "$k8s_test" ]] || fail "the Kubernetes Relayer smoke test $k8s_test is missing"
done

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

# ---------------------------------------------------------------------------
# Kubernetes path. Everything above stays the Terraform/Ansible contract; this
# section holds the Kubernetes contract and reuses the helpers defined above.
# ---------------------------------------------------------------------------

# make k8s-relayer must stay zero-input: no addresses, keys, or identifiers, and
# no direct helm invocation that would bypass discovery and the doctor gate.
# make -n prints the recipe already expanded, so anchoring on end-of-line is what
# proves no variable-driven argument (a subnet id, a manager address, a key) can
# be forwarded: after `install` there must be nothing at all.
k8s_install_recipe="$(make -n k8s-relayer)"
grep -Eq './scripts/relayer\.sh install[[:space:]]*$' <<<"$k8s_install_recipe" || \
    fail "make k8s-relayer does not use automatic discovery: the installer must be invoked as './scripts/relayer.sh install' with no arguments"
if grep -Eq 'helm |--set ' <<<"$k8s_install_recipe"; then
    fail "make k8s-relayer installs the chart directly, bypassing discovery and the doctor gate"
fi
for target in k8s-relayer k8s-relayer-prereqs k8s-relayer-doctor k8s-relayer-access k8s-relayer-status \
    k8s-relayer-logs k8s-relayer-backup k8s-relayer-upgrade k8s-relayer-remove; do
    make -n "$target" >/dev/null || fail "make $target is not dry-runnable"
done
make -n k8s-relayer-restore BACKUP=manual-19700101T000000Z.tar.gz >/dev/null || \
    fail "Kubernetes restore target is not dry-runnable"

# RELAYER_VERSION selects the release the driver downloads and verifies, and
# RELAYER_PRERELEASE_FALLBACK the reviewed prerelease used until an official one
# exists. Pinning both literals in the Makefile and in the driver stays green with
# the forwarding entirely absent, because the driver then silently uses its own
# defaults, so drive make with sentinel values and require the recipe to carry them.
for target in k8s-relayer k8s-relayer-doctor k8s-relayer-upgrade; do
    k8s_forward_recipe="$(make -n "$target" RELAYER_VERSION=v9.9.9-probe RELAYER_PRERELEASE_FALLBACK=v8.8.8-probe)"
    grep -Fq 'RELAYER_VERSION="v9.9.9-probe"' <<<"$k8s_forward_recipe" || \
        fail "make $target does not forward RELAYER_VERSION into the Kubernetes driver"
    grep -Fq 'RELAYER_PRERELEASE_FALLBACK="v8.8.8-probe"' <<<"$k8s_forward_recipe" || \
        fail "make $target does not forward RELAYER_PRERELEASE_FALLBACK into the Kubernetes driver"
done
# The restore path re-downloads the release when the recorded digest is unusable,
# so it needs the same two selectors as the installer alongside BACKUP.
k8s_restore_recipe="$(make -n k8s-relayer-restore BACKUP=manual-19700101T000000Z.tar.gz \
    RELAYER_VERSION=v9.9.9-probe RELAYER_PRERELEASE_FALLBACK=v8.8.8-probe)"
grep -Fq 'RELAYER_VERSION="v9.9.9-probe"' <<<"$k8s_restore_recipe" || \
    fail "make k8s-relayer-restore drops the RELAYER_VERSION pin, so a restore that re-downloads the release ignores the operator's selection"
grep -Fq 'RELAYER_PRERELEASE_FALLBACK="v8.8.8-probe"' <<<"$k8s_restore_recipe" || \
    fail "make k8s-relayer-restore does not forward RELAYER_PRERELEASE_FALLBACK into the Kubernetes driver"

# Anchored so "make k8s-relayer" cannot be satisfied by "make k8s-relayer-prereqs".
k8s_help="$(make k8s-help)"
k8s_help_l1="$(make k8s-help-l1)"
for command in "${K8S_COMMANDS[@]}"; do
    grep -Eq "make $command([^-]|\$)" <<<"$k8s_help" || fail "k8s-help omits $command"
    grep -Eq "make $command([^-]|\$)" <<<"$k8s_help_l1" || fail "k8s-help-l1 omits $command"
    grep -Eq "make $command([^-]|\$)" <<<"$all_help" || fail "help-all omits $command"
done

# --- Kubernetes driver: prompts, guards, and the doctor -------------------
require_file_text "$K8S_SCRIPT" 'Install the relayer and console on %s? [y/N] '
require_file_text "$K8S_SCRIPT" 'Console password (press Enter for none): '
[[ "$(grep -Fc 'Install the relayer and console on %s? [y/N] ' "$K8S_SCRIPT")" -eq 1 ]] || \
    fail "Kubernetes installer target prompt is not unique"
[[ "$(grep -Fc 'Console password (press Enter for none): ' "$K8S_SCRIPT")" -eq 1 ]] || \
    fail "Kubernetes installer password prompt is not unique"
# doctor_k8s takes doctor_vm's scope parameter, so an unrecognised scope must be a
# hard internal error rather than a silently permissive run. Behavioural: the scope
# is validated before anything touches a cluster, so this needs no stubs.
k8s_doctor_scope_error="$(bash -c 'source '"$K8S_SCRIPT"'; doctor_k8s bogus' 2>&1 || true)"
grep -Fq "internal error: unsupported Relayer doctor scope 'bogus'" <<<"$k8s_doctor_scope_error" || \
    fail "doctor_k8s does not reject an unsupported diagnostic scope"
# The k8s doctor must keep using the shared formatter, not grow its own.
require_file_text "$K8S_SCRIPT" 'source "$ROOT_DIR/scripts/shared/relayer-doctor-lib.sh"'
require_file_text "$K8S_SCRIPT" 'paths and traversal are rejected'

# The retained backup manifest carries public chain metadata and an archive
# checksum only. It must never record a checksum of the console credential,
# which would make the manifest a verifier for a secret.
k8s_backup_body="$(function_body "$K8S_SCRIPT" backup_relayer)"
[[ -n "$k8s_backup_body" ]] || fail "backup_relayer function body could not be located in $K8S_SCRIPT"
grep -Fq 'kind:"avalanche-deploy-relayer-backup"' <<<"$k8s_backup_body" || \
    fail "backup_relayer no longer writes an Avalanche Deploy backup manifest"
grep -Fq 'credentialSha256' <<<"$k8s_backup_body" && \
    fail "the Kubernetes backup manifest records a credential checksum"

# --- Release source: official repository, selector, prerelease fallback ---
require_file_text "$K8S_SCRIPT" 'OFFICIAL_RELAYER_REPOSITORY="ava-labs/avalanche-vmc-relayer"'
if grep -R -Eq 'ava-labs/Relayer|ava-labs/validator-lifecycle-relayer' "$K8S_SCRIPT" "$K8S_CHART" kubernetes/README.md; then
    fail "the Kubernetes Relayer path still references a superseded release repository name"
fi
require_file_text "$K8S_SCRIPT" 'DEFAULT_RELAYER_VERSION_SELECTOR="official-latest"'
require_file_text "$K8S_SCRIPT" 'RELAYER_VERSION="${RELAYER_VERSION:-$DEFAULT_RELAYER_VERSION_SELECTOR}"'
require_file_text "$K8S_SCRIPT" 'RELAYER_PRERELEASE_FALLBACK="${RELAYER_PRERELEASE_FALLBACK:-v0.1.0-rc.8}"'
require_file_text "$K8S_SCRIPT" 'https://api.github.com/repos/$OFFICIAL_RELAYER_REPOSITORY/releases?per_page=100'

# Behavioural, not textual: the driver is sourceable, so drive the resolver with
# a stubbed releases query instead of trusting that the greps above still work.
# Every Makefile target forwards RELAYER_VERSION=official-latest, so a resolver
# that rejected or ignored the selector would break the whole path.
k8s_resolved_stable="$(bash -c '
    source '"$K8S_SCRIPT"'
    official_latest_release_tag() { echo v9.9.9; }
    resolve_release_version
    printf "%s" "$RELAYER_VERSION"' 2>/dev/null)"
[[ "$k8s_resolved_stable" == "v9.9.9" ]] || \
    fail "the k8s driver does not resolve official-latest to the newest official production release (got '$k8s_resolved_stable')"
k8s_resolved_fallback="$(bash -c '
    source '"$K8S_SCRIPT"'
    official_latest_release_tag() { printf ""; }
    resolve_release_version
    printf "%s" "$RELAYER_VERSION"' 2>/dev/null)"
[[ "$k8s_resolved_fallback" == "v0.1.0-rc.8" ]] || \
    fail "the k8s driver does not fall back to the reviewed prerelease when no official release exists (got '$k8s_resolved_fallback')"
if bash -c '
    source '"$K8S_SCRIPT"'
    official_latest_release_tag() { return 1; }
    resolve_release_version' >/dev/null 2>&1; then
    fail "the k8s driver silently accepts an unreachable GitHub releases query instead of failing closed"
fi
# An explicit malformed tag must still be rejected before anything is dispatched.
k8s_version_error="$(RELAYER_VERSION=notatag "./$K8S_SCRIPT" doctor 2>&1 || true)"
grep -Fq 'RELAYER_VERSION must be official-latest or a release tag' <<<"$k8s_version_error" || \
    fail "the k8s driver does not reject a malformed RELAYER_VERSION with the official-latest-aware message"
# Ordering: the selector must be resolved before the tag shape is validated, or
# official-latest would be rejected as a malformed tag.
k8s_main_body="$(function_body "$K8S_SCRIPT" main)"
[[ -n "$k8s_main_body" ]] || fail "main function body could not be located in $K8S_SCRIPT"
k8s_resolve_line="$(grep -Fn 'resolve_release_version' <<<"$k8s_main_body" | head -1 | cut -d: -f1)" || true
k8s_validate_line="$(grep -Fn 'must be official-latest or a release tag' <<<"$k8s_main_body" | cut -d: -f1)" || true
[[ -n "$k8s_resolve_line" && -n "$k8s_validate_line" ]] || \
    fail "main() is missing the release resolution or the release tag validation"
[[ "$k8s_resolve_line" -lt "$k8s_validate_line" ]] || \
    fail "main() validates the release tag before resolving the official-latest selector"

# --- Daemon API port 8081, and the Safe UI port that must stay 8080 -------
# relayerd moved off 8080 because Safe's Nginx redirect and the ICM Relayer both
# bind it. A naive global 8080 -> 8081 replace would also rewrite the Safe UI
# Service URL the console is handed, so both halves are pinned here.
if grep -Fq '127.0.0.1:8080' "$K8S_SCRIPT"; then
    fail "the k8s driver still probes the daemon on port 8080, which Safe and the ICM Relayer occupy"
fi
[[ "$(grep -Fc 'fetch("http://127.0.0.1:8081/keys")' "$K8S_SCRIPT")" -eq 2 ]] || \
    fail "the k8s driver no longer reads funding key addresses from the daemon API on loopback port 8081"
require_file_text "$K8S_SCRIPT" '"http://"+$safeUi+":8080"'
require_file_text "$K8S_VALUES" 'api: 8081'

# --- Chart render: assert on the rendered objects, not the templates ------
k8s_render_values=(
    --set runtimeSecret.name=relayer-runtime
    --set operatorIdentity=test-operator
    --set l1.subnetId=test-subnet
    --set l1.blockchainId=test-blockchain
    --set l1.evmChainId=99999
    --set l1.chainName=test-chain
    --set l1.managerAddress=0x1111111111111111111111111111111111111111
    --set l1.validatorManagerAddress=0x2222222222222222222222222222222222222222
)
k8s_render="$(helm template relayer "$K8S_CHART" "${k8s_render_values[@]}")" || \
    fail "the relayerd chart does not render with the documented installer values"

[[ "$(grep -Ec '^kind: StatefulSet$' <<<"$k8s_render")" -eq 1 ]] || \
    fail "the relayerd chart does not render exactly one StatefulSet"
# The installer owns the runtime Secret and access is port-forward only, so the
# chart must never own key material or a reachable endpoint.
for forbidden_kind in Service Ingress Secret; do
    [[ "$(grep -Ec "^kind: $forbidden_kind\$" <<<"$k8s_render")" -eq 0 ]] || \
        fail "the relayerd chart renders a $forbidden_kind object"
done
[[ "$(grep -Ec '^  replicas: 1$' <<<"$k8s_render")" -eq 1 ]] || \
    fail "the rendered StatefulSet is not a single replica"
grep -Eq '^  replicas: (0|[2-9]|[0-9]{2,})' <<<"$k8s_render" && \
    fail "the rendered StatefulSet declares a replica count other than 1"
grep -Eq '^        - name: relayerd$' <<<"$k8s_render" || fail "the rendered pod has no relayerd container"
grep -Eq '^        - name: console$' <<<"$k8s_render" || fail "the rendered pod has no console container"

# Default-deny ingress: no pod, Service, ingress controller, or load balancer
# may connect, so there must be no ingress rule at all.
grep -Eq '^  ingress: \[\]$' <<<"$k8s_render" || \
    fail "the rendered NetworkPolicy does not deny all ingress"
grep -Eq '^    - Ingress$' <<<"$k8s_render" || \
    fail "the rendered NetworkPolicy does not declare the Ingress policy type, so denying ingress has no effect"
grep -Eq '^[[:space:]]*- from:' <<<"$k8s_render" && \
    fail "the rendered NetworkPolicy grants an ingress source"

# The access Role is a port-forward Role: create on pods/portforward, read on the
# two named objects kubectl port-forward resolves first, and nothing that reaches
# key material or a running process.
#
# Presence greps are not enough here, and neither is `grep -A1` on a resource line:
# -A1 emits a follower for every match and -q needs only one of them to match, so a
# SECOND rule always passed. An unnamed configmaps rule granting read of every
# ConfigMap in the L1 namespace, and a second pods rule adding watch, both survived
# the earlier assertions. So parse the rules and require the whole set: one rule per
# line, comments stripped, whitespace normalised.
k8s_role_rules="$(awk '
    /^kind: Role$/ { in_role=1; next }
    in_role && /^rules:/ { in_rules=1; next }
    in_rules && /^---$/ { exit }
    in_rules { print }
' <<<"$k8s_render" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$' | awk '
    /^  - / { if (rule != "") print rule; rule = $0; next }
    { rule = rule " " $0 }
    END { if (rule != "") print rule }
' | sed -E 's/[[:space:]]+/ /g; s/^ //')"
[[ -n "$k8s_role_rules" ]] || fail "the rendered access Role has no parsable rules"
# Every ConfigMap and Service rule must name its single object, and pods must stay
# read-only. Stated per rule first, so the failure names the defect rather than the
# rule count.
while IFS= read -r role_rule; do
    case "$role_rule" in
        *'resources: ["configmaps"]'*)
            [[ "$role_rule" == *'resourceNames: ["l1-config"]'* ]] || \
                fail "a rendered access Role rule reads ConfigMaps without restricting them to l1-config by name: $role_rule" ;;
        *'resources: ["services"]'*)
            [[ "$role_rule" == *'resourceNames: ["l1-rpc"]'* ]] || \
                fail "a rendered access Role rule reads Services without restricting them to l1-rpc by name: $role_rule" ;;
        *'resources: ["pods"]'*)
            [[ "$role_rule" == *'verbs: ["get", "list"]'* ]] || \
                fail "a rendered access Role rule grants pods verbs other than get/list: $role_rule" ;;
    esac
done <<<"$k8s_role_rules"
# Then the whole set, so a rule that is individually harmless but outside the
# contract, or one added beside these four, still fails.
[[ "$(grep -c . <<<"$k8s_role_rules")" -eq 4 ]] || \
    fail "the rendered access Role declares $(grep -c . <<<"$k8s_role_rules") rules instead of the four port-forward rules; a rule added beside them widens the operator identity"
while IFS= read -r role_rule; do
    case "$role_rule" in
        '- apiGroups: [""] resources: ["pods"] verbs: ["get", "list"]') ;;
        '- apiGroups: [""] resources: ["pods/portforward"] verbs: ["create"]') ;;
        '- apiGroups: [""] resources: ["services"] resourceNames: ["l1-rpc"] verbs: ["get"]') ;;
        '- apiGroups: [""] resources: ["configmaps"] resourceNames: ["l1-config"] verbs: ["get"]') ;;
        *) fail "the rendered access Role grants a rule outside the port-forward contract: $role_rule" ;;
    esac
done <<<"$k8s_role_rules"
[[ "$(grep -Fc 'verbs: ["create"]' <<<"$k8s_render")" -eq 1 ]] || \
    fail "the rendered access Role grants create on something other than pods/portforward"
if grep -Eq '"secrets"|pods/exec|pods/log' <<<"$k8s_render"; then
    fail "the rendered access Role grants secret, exec, or log access"
fi
if grep -Eq 'verbs: \[[^]]*"(delete|deletecollection|patch|update|\*)"' <<<"$k8s_render"; then
    fail "the rendered access Role grants a mutating verb"
fi

# Both workload images must be immutable ghcr.io digests, and no image anywhere
# in the render may carry a mutable tag.
[[ "$(grep -Ec '^          image: "ghcr\.io/ava-labs/[a-z-]+@sha256:[0-9a-f]{64}"$' <<<"$k8s_render")" -eq 2 ]] || \
    fail "the rendered pod does not pin both ghcr.io Relayer images to an immutable sha256 digest"
while IFS= read -r image_line; do
    grep -Fq '@sha256:' <<<"$image_line" || \
        fail "the rendered pod carries a mutable image tag: ${image_line#* }"
done < <(grep -E '^[[:space:]]*image:' <<<"$k8s_render")

# The console never receives an automatic loopback wallet RPC URL: the pinned
# tunnel URL only resolved while k8s-relayer-access held its port-forward, and
# every wallet call failed as an opaque JSON-RPC -32603 without it. The explicit
# operator override must still work, so both directions are asserted.
grep -Eq '^[[:space:]]*- name: WALLET_RPC_URL$' <<<"$k8s_render" && \
    fail "the chart renders an automatic WALLET_RPC_URL default for the console wallet"
k8s_wallet_override_render="$(helm template relayer "$K8S_CHART" "${k8s_render_values[@]}" \
    --set console.walletRpcUrl=https://rpc.example.invalid/ext/bc/x/rpc)" || \
    fail "the relayerd chart does not render with an explicit console.walletRpcUrl override"
grep -Eq '^[[:space:]]*- name: WALLET_RPC_URL$' <<<"$k8s_wallet_override_render" || \
    fail "an explicit console.walletRpcUrl override no longer renders WALLET_RPC_URL"

# Rendered daemon endpoints: the config listener, the console base URL, and all
# three probes must agree on 8081, and 8080 must appear nowhere.
grep -Fq '"api-listen-addr": "127.0.0.1:8081"' <<<"$k8s_render" || \
    fail "the rendered daemon config does not bind the API to loopback port 8081"
grep -Fq 'value: http://127.0.0.1:8081' <<<"$k8s_render" || \
    fail "the rendered console does not reach the daemon on loopback port 8081"
grep -Fq '8080' <<<"$k8s_render" && \
    fail "the rendered relayerd objects reference port 8080, which Safe and the ICM Relayer occupy"

# Probe ownership and budgets. kubelet restarts the container whose probe failed,
# so WHICH container carries a probe is the safety property, not merely that a probe
# with the right endpoint exists somewhere in the render: a daemon endpoint in the
# console's startup or liveness probe restarts the operator's console forever while
# the wedged daemon is never touched. Extracting by field name alone read whichever
# container happened to come first and could not see that the other had no probes at
# all, so every probe here is extracted from its own container block.
container_block() {
    awk -v marker="        - name: $1" '
        $0 == marker { found=1; next }
        found && /^        - name: / { exit }
        found { print }
    ' <<<"$k8s_render"
}
probe_block() {
    awk -v probe="$2:" '
        $1 == probe { found=1; next }
        found && ($1 ~ /Probe:$/ || $1 == "securityContext:" || $1 == "ports:" || $1 == "env:") { exit }
        found { print }
    ' <<<"$1"
}
probe_number() {
    awk -v field="$2:" '$1 == field { print $2; exit }' <<<"$1"
}
probe_budget_of() {
    local body="$1" name="$2" period threshold
    period="$(probe_number "$body" periodSeconds)"
    threshold="$(probe_number "$body" failureThreshold)"
    [[ "$period" =~ ^[0-9]+$ && "$threshold" =~ ^[0-9]+$ ]] || \
        fail "$name does not declare a numeric periodSeconds and failureThreshold"
    echo $((period * threshold))
}

# The startup budget is a ceiling derived from the installer, not a bare number.
# The installer's single `helm upgrade --install --atomic --wait` covers everything
# from pod creation to pod Ready, and the startupProbe suppresses readiness while it
# runs, so a budget at or above that wait cannot be spent: helm rolls the release
# back first. The previous assertion (>= 1800s) was satisfied precisely by the value
# that guaranteed the rollback. 300s is reserved for scheduling, PVC binding, three
# image pulls, and the init container; the floor keeps the budget from shrinking to
# nothing, since the VM path proves relayerd can need 300s to answer /ready
# (acp_relayer_ready_retries 60 x acp_relayer_ready_delay 5s).
k8s_timeout_literal="$(sed -nE 's/^TIMEOUT="\$\{RELAYER_TIMEOUT:-([0-9]+[hms])\}"$/\1/p' "$K8S_SCRIPT")"
case "$k8s_timeout_literal" in
    *h) k8s_install_wait=$(( ${k8s_timeout_literal%h} * 3600 )) ;;
    *m) k8s_install_wait=$(( ${k8s_timeout_literal%m} * 60 )) ;;
    *s) k8s_install_wait=$(( ${k8s_timeout_literal%s} )) ;;
    *) fail "the installer wait RELAYER_TIMEOUT could not be read from $K8S_SCRIPT" ;;
esac
k8s_startup_ceiling=$((k8s_install_wait - 300))
[[ "$k8s_startup_ceiling" -ge 150 ]] || \
    fail "the installer wait of ${k8s_install_wait}s leaves no room for a startup probe budget above the 150s the VM path needs"

# The relayerd container owns every daemon probe: /health for startup and liveness,
# /ready for readiness. Liveness must outlast an RPC rollout because /health also
# covers the P-Chain, Info, and EVM RPCs the daemon reaches through the discovered
# avalanchego Service. Readiness stays tight; it only withholds the pod.
k8s_relayerd_container="$(container_block relayerd)"
[[ -n "$k8s_relayerd_container" ]] || fail "the rendered pod has no relayerd container block"
for probe in startupProbe livenessProbe readinessProbe; do
    probe_body="$(probe_block "$k8s_relayerd_container" "$probe")"
    [[ -n "$probe_body" ]] || \
        fail "the rendered relayerd container has no $probe, so kubelet never restarts the daemon that wedged"
    probe_budget="$(probe_budget_of "$probe_body" "relayerd $probe")"
    case "$probe" in
        startupProbe)
            grep -Fq '127.0.0.1:8081/health' <<<"$probe_body" || \
                fail "the relayerd $probe does not gate on the daemon /health endpoint"
            [[ "$probe_budget" -le "$k8s_startup_ceiling" ]] || \
                fail "the relayerd startup budget of ${probe_budget}s exceeds the ${k8s_startup_ceiling}s the installer's ${k8s_install_wait}s atomic wait can actually spend, so helm rolls the release back before the budget is used"
            [[ "$probe_budget" -ge 150 ]] || \
                fail "the relayerd startup budget of ${probe_budget}s is below the 150s a cold relayerd start needs to answer /ready"
            ;;
        livenessProbe)
            grep -Fq '127.0.0.1:8081/health' <<<"$probe_body" || \
                fail "the relayerd $probe does not gate on the daemon /health endpoint"
            [[ "$probe_budget" -ge 600 ]] || \
                fail "the relayerd liveness budget of ${probe_budget}s restarts the daemon on an RPC rollout or blip (needs >= 600s)"
            ;;
        readinessProbe)
            grep -Fq '127.0.0.1:8081/ready' <<<"$probe_body" || \
                fail "the relayerd $probe does not gate on the daemon /ready endpoint"
            [[ "$probe_budget" -le 60 ]] || \
                fail "the relayerd readiness budget of ${probe_budget}s no longer withholds an unready daemon promptly (needs <= 60s)"
            ;;
    esac
done

# The console container may only restart for its own faults. Readiness is the one
# place the daemon dependency belongs, because readiness withholds the pod and never
# restarts anything, and an operator handed a console whose daemon cannot answer is
# worse off than one handed no console. This is the Kubernetes form of the VM fix
# that made relayer-console.service Wants= rather than Requires= relayerd.service.
k8s_console_container="$(container_block console)"
[[ -n "$k8s_console_container" ]] || fail "the rendered pod has no console container block"
for probe in startupProbe livenessProbe readinessProbe; do
    probe_body="$(probe_block "$k8s_console_container" "$probe")"
    [[ -n "$probe_body" ]] || fail "the rendered console container has no $probe"
    probe_budget="$(probe_budget_of "$probe_body" "console $probe")"
    grep -Fq '127.0.0.1:3080/api/auth/session' <<<"$probe_body" || \
        fail "the console $probe does not check the console's own HTTP endpoint"
    if [[ "$probe" != readinessProbe ]]; then
        grep -Fq '8081' <<<"$probe_body" && \
            fail "the console $probe checks the daemon API on 8081, so kubelet restarts the operator's console for the daemon's fault"
        [[ "$probe_budget" -le "$k8s_startup_ceiling" ]] || \
            fail "the console $probe budget of ${probe_budget}s exceeds the ${k8s_startup_ceiling}s the installer's atomic wait can spend"
    fi
    case "$probe" in
        startupProbe)
            [[ "$probe_budget" -ge 60 ]] || \
                fail "the console startup budget of ${probe_budget}s restarts the console over a slow first render"
            ;;
        livenessProbe)
            [[ "$probe_budget" -ge 120 ]] || \
                fail "the console liveness budget of ${probe_budget}s restarts the console over a slow render rather than a wedged server (needs >= 120s)"
            ;;
        readinessProbe)
            grep -Fq '127.0.0.1:8081/ready' <<<"$probe_body" || \
                fail "the console readinessProbe no longer withholds the pod when the daemon cannot answer /ready"
            [[ "$probe_budget" -le 60 ]] || \
                fail "the console readiness budget of ${probe_budget}s no longer withholds an unready console promptly (needs <= 60s)"
            ;;
    esac
done

# The chart is single-instance by construction: relayerd holds an exclusive
# bbolt lock, so a second replica would corrupt state rather than scale.
if helm template relayer "$K8S_CHART" "${k8s_render_values[@]}" --set replicas=2 >/dev/null 2>&1; then
    fail "the relayerd chart accepts more than one replica"
fi
# An operator must never install a Relayer against a half-populated L1 identity.
if helm template relayer "$K8S_CHART" >/dev/null 2>&1; then
    fail "the relayerd chart no longer fails closed when the required installer values are absent"
fi

# --- preflight: PoAManager owner classification --------------------------
# A renounced (zero-address) owner leaves nobody able to approve validator
# changes, and an unanswered eth_getCode cannot be classified at all. Both must
# be fatal before OWNER_TYPE defaults to EOA, or a Safe-owned or ownerless L1
# would be installed as an EOA-owned one.
k8s_preflight_body="$(function_body "$K8S_SCRIPT" preflight)"
[[ -n "$k8s_preflight_body" ]] || fail "preflight function body could not be located in $K8S_SCRIPT"
poa_owner_line="$(grep -Fn 'POA_OWNER="0x${owner_word: -40}"' <<<"$k8s_preflight_body" | cut -d: -f1)" || true
zero_owner_line="$(grep -Fn 'is the zero address; a renounced owner' <<<"$k8s_preflight_body" | cut -d: -f1)" || true
owner_code_line="$(grep -Fn 'did not answer eth_getCode for PoAManager owner' <<<"$k8s_preflight_body" | cut -d: -f1)" || true
owner_type_line="$(grep -Fn 'OWNER_TYPE="EOA"' <<<"$k8s_preflight_body" | cut -d: -f1)" || true
[[ -n "$poa_owner_line" && -n "$zero_owner_line" && -n "$owner_code_line" && -n "$owner_type_line" ]] || \
    fail "preflight is missing the PoAManager owner derivation, the zero-address assert, the eth_getCode assert, or the EOA default"
[[ "$poa_owner_line" -lt "$zero_owner_line" && "$zero_owner_line" -lt "$owner_code_line" && \
    "$owner_code_line" -lt "$owner_type_line" ]] || \
    fail "preflight must reject a renounced owner and an unanswered eth_getCode before defaulting OWNER_TYPE to EOA"
require_file_text "$K8S_SCRIPT" 'is a contract but not a compatible Safe'

# --- install_relayer: doctor first, then a recovery point ----------------
# Reapplying over an existing install mutates live state, so it must leave a
# recovery point first, exactly once, after the console password is collected
# and before the release is downloaded.
k8s_install_body="$(function_body "$K8S_SCRIPT" install_relayer)"
[[ -n "$k8s_install_body" ]] || fail "install_relayer function body could not be located in $K8S_SCRIPT"
[[ "$(grep -Fc 'backup_relayer' <<<"$k8s_install_body")" -eq 1 ]] || \
    fail "install_relayer must call backup_relayer exactly once when reapplying over existing state"
grep -Fq 'helm status "$RELAYER_RELEASE" -n "$NAMESPACE"' <<<"$k8s_install_body" || \
    fail "install_relayer no longer guards the reapply backup on an existing Helm release"
grep -Fq 'get statefulset relayer' <<<"$k8s_install_body" || \
    fail "install_relayer no longer guards the reapply backup on the StatefulSet backup_relayer scales"
# install scope, not the default operations scope: the installer must not block on
# the checks it is about to repair.
k8s_doctor_gate_line="$(grep -Fn 'if ! doctor_k8s install; then' <<<"$k8s_install_body" | cut -d: -f1)" || true
k8s_password_line="$(grep -Fn 'read -r -s console_password' <<<"$k8s_install_body" | cut -d: -f1)" || true
k8s_backup_guard_line="$(grep -Fn 'helm status "$RELAYER_RELEASE" -n "$NAMESPACE"' <<<"$k8s_install_body" | cut -d: -f1)" || true
k8s_backup_call_line="$(grep -Fn 'backup_relayer' <<<"$k8s_install_body" | cut -d: -f1)" || true
k8s_download_line="$(grep -Fn 'download_release true' <<<"$k8s_install_body" | cut -d: -f1)" || true
[[ -n "$k8s_doctor_gate_line" && -n "$k8s_password_line" && -n "$k8s_backup_guard_line" && \
    -n "$k8s_backup_call_line" && -n "$k8s_download_line" ]] || \
    fail "install_relayer is missing the doctor gate, the console password prompt, the backup guard, the backup call, or the release download"
[[ "$k8s_doctor_gate_line" -lt "$k8s_password_line" && "$k8s_password_line" -lt "$k8s_backup_guard_line" && \
    "$k8s_backup_guard_line" -lt "$k8s_backup_call_line" && "$k8s_backup_call_line" -lt "$k8s_download_line" ]] || \
    fail "install_relayer no longer runs the doctor, prompts for the console password, then backs up existing state before downloading the release"

# --- restore: rollback matrix and staged secrets on every failure path ----
# .restore-stage is the extracted archive: the node P2P TLS private key
# tls/staker.key and the encrypted keystore. Every path that can leave it behind
# must remove it, the cleanup must never mask the original error, and any failure
# after the bbolt database has been rewritten must reapply the pre-restore archive
# instead of restarting the daemon on half-written state.
k8s_restore_body="$(function_body "$K8S_SCRIPT" restore_relayer)"
[[ -n "$k8s_restore_body" ]] || fail "restore_relayer function body could not be located in $K8S_SCRIPT"
[[ "$(grep -Fc 'clean_restore_stage "$cleanup_pod" "$claim"' <<<"$k8s_restore_body")" -ge 3 ]] || \
    fail "restore_relayer no longer removes the staged restore material on its explicit failure paths"
grep -Fq 'cleanup_pod="relayer-restore-cleanup"' <<<"$k8s_restore_body" || \
    fail "restore_relayer no longer declares the restore-stage cleanup pod"

# Every pod the restore creates must be created under a guard. Under set -e an
# unchecked `printf | kubectl apply` that the API server refuses (an admission
# webhook, a ResourceQuota, a transient 500) aborts past the rollback branch that
# exists for exactly that failure, leaving the workload to restart on new state.
k8s_restore_applies="$(grep -F 'kubectl -n "$NAMESPACE" apply -f -' <<<"$k8s_restore_body")"
[[ "$(grep -c . <<<"$k8s_restore_applies")" -ge 7 ]] || \
    fail "restore_relayer creates fewer pods than its validation, staging, database, identity, and rollback steps need; this check would pass over the ones that remain"
while IFS= read -r apply_line; do
    grep -Eq '^[[:space:]]*if ! printf|\|\| \\$' <<<"$apply_line" || \
        fail "restore_relayer creates a pod without checking that the apply itself succeeded:${apply_line#*printf}"
done <<<"$k8s_restore_applies"

# relayer-restore rewrites /data/relayer.db in place, so its failure is not a
# no-op: the pre-restore archive must be reapplied, and if that rollback also
# fails BACKUP_REPLICAS must be cleared before the die, or the EXIT trap scales
# the daemon back up onto a half-written database.
k8s_db_failure_block="$(awk '
    index($0, "\"pod/$utility_pod\" --timeout") { inside=1 }
    inside { print }
    inside && index($0, "the pre-restore state was reapplied") { exit }
' <<<"$k8s_restore_body")"
[[ -n "$k8s_db_failure_block" ]] || \
    fail "restore_relayer has no relayer-restore failure branch that reapplies the pre-restore state"
grep -Fq -- '--arg name "$rollback_pod"' <<<"$k8s_db_failure_block" || \
    fail "a failed relayer-restore leaves the rewritten bbolt database in place instead of reapplying the pre-restore archive"
k8s_rollback_clear_line="$(grep -Fn 'BACKUP_REPLICAS=""' <<<"$k8s_db_failure_block" | head -1 | cut -d: -f1)" || true
k8s_rollback_failed_line="$(grep -Fn 'automatic rollback also failed' <<<"$k8s_db_failure_block" | head -1 | cut -d: -f1)" || true
[[ -n "$k8s_rollback_clear_line" && -n "$k8s_rollback_failed_line" ]] || \
    fail "the relayer-restore failure branch is missing the rollback-failed path or its BACKUP_REPLICAS reset"
[[ "$k8s_rollback_clear_line" -lt "$k8s_rollback_failed_line" ]] || \
    fail "a failed rollback after a failed relayer-restore leaves BACKUP_REPLICAS set, so the EXIT trap scales the daemon up onto a half-written database"

# Stage cleanup is a trap guarantee, not a set of explicit call sites: counting the
# call sites says nothing about the paths that had none. The trap must remove the
# stage before it rescales the workload, because the cleanup pod cannot mount the
# ReadWriteOnce claim once the daemon holds it.
k8s_cleanup_trap_body="$(function_body "$K8S_SCRIPT" cleanup)"
[[ -n "$k8s_cleanup_trap_body" ]] || fail "cleanup function body could not be located in $K8S_SCRIPT"
grep -Fq 'clean_restore_stage "$RESTORE_STAGE_POD" "$RESTORE_STAGE_CLAIM"' <<<"$k8s_cleanup_trap_body" || \
    fail "the exit trap does not remove staged restore material, so an interrupt or an unguarded kubectl failure leaves the node P2P TLS private key on the PVC"
k8s_trap_clean_line="$(grep -Fn 'clean_restore_stage "$RESTORE_STAGE_POD"' <<<"$k8s_cleanup_trap_body" | head -1 | cut -d: -f1)" || true
k8s_trap_rescale_line="$(grep -Fn 'scale statefulset/relayer --replicas="$BACKUP_REPLICAS"' <<<"$k8s_cleanup_trap_body" | cut -d: -f1)" || true
[[ -n "$k8s_trap_clean_line" && -n "$k8s_trap_rescale_line" ]] || \
    fail "cleanup is missing the staged-material removal or the workload rescale"
[[ "$k8s_trap_clean_line" -lt "$k8s_trap_rescale_line" ]] || \
    fail "cleanup rescales the workload before removing the staged material, and the cleanup pod can no longer mount the ReadWriteOnce claim"
# INT/TERM must end the run rather than fall through to the shared EXIT handler:
# bash otherwise resumes the interrupted kubectl wait and continues a restore whose
# stage the handler has just deleted.
require_file_text "$K8S_SCRIPT" "trap 'cleanup; exit 130' INT"
require_file_text "$K8S_SCRIPT" "trap 'cleanup; exit 143' TERM"
# The markers must be armed before the pod that creates .restore-stage runs, or an
# interrupt during that pod leaves the trap with nothing to clean.
k8s_stage_claim_line="$(grep -Fn 'RESTORE_STAGE_CLAIM="$claim"' <<<"$k8s_restore_body" | head -1 | cut -d: -f1)" || true
k8s_stage_pod_line="$(grep -Fn 'RESTORE_STAGE_POD="$cleanup_pod"' <<<"$k8s_restore_body" | head -1 | cut -d: -f1)" || true
k8s_stage_wait_line="$(grep -Fn '"pod/$restore_pod" --timeout' <<<"$k8s_restore_body" | tail -1 | cut -d: -f1)" || true
[[ -n "$k8s_stage_claim_line" && -n "$k8s_stage_pod_line" && -n "$k8s_stage_wait_line" ]] || \
    fail "restore_relayer no longer arms the restore-stage cleanup markers the exit trap reads"
[[ "$k8s_stage_claim_line" -lt "$k8s_stage_wait_line" && "$k8s_stage_pod_line" -lt "$k8s_stage_wait_line" ]] || \
    fail "the restore-stage cleanup markers are armed after the pod that creates .restore-stage, so an interrupt during that pod leaks the staged material"
grep -Fq '"$rollback_pod" "$cleanup_pod"' <<<"$k8s_restore_body" || \
    fail "restore_relayer no longer deletes a stale restore-stage cleanup pod before it runs"
k8s_cleanup_body="$(function_body "$K8S_SCRIPT" clean_restore_stage)"
[[ -n "$k8s_cleanup_body" ]] || fail "clean_restore_stage function body could not be located in $K8S_SCRIPT"
grep -Fq 'rm -rf .restore-stage' <<<"$k8s_cleanup_body" || \
    fail "clean_restore_stage does not remove the staged restore material"
# The last statement must be an unconditional `return 0`, or a failed cleanup
# would replace the original restore failure with its own exit status.
[[ "$(grep -v '^[[:space:]]*$' <<<"$k8s_cleanup_body" | tail -2 | head -1)" == "    return 0" ]] || \
    fail "clean_restore_stage does not end in an unconditional return 0, so it can mask the original restore failure"
grep -Fq 'staged restore material could not be removed' <<<"$k8s_cleanup_body" || \
    fail "clean_restore_stage does not warn when the staged secrets survive"

# Archives and the staging directory carry secrets, so they must not be written
# under the default umask. Mirrors the VM restore workspace 0700 / archive 0600.
# Each pattern names the object it protects: a pattern stopping at `backups/` was
# equally satisfied by `chmod 600 "backups/"`, which tightens the directory and
# leaves the archives inside it world-readable at the pod's umask.
grep -Fq 'chmod 700 .restore-stage' <<<"$k8s_restore_body" || \
    fail "the restore staging directory is created without a restrictive 0700 mode"
grep -Fq 'chmod 600 \"backups/"+$pre+"\"' <<<"$k8s_restore_body" || \
    fail "the pre-restore rollback archive itself is created without a restrictive 0600 mode"
grep -Fq 'chmod 600 \"backups/"+$archive+"\"' <<<"$k8s_backup_body" || \
    fail "the manual backup archive itself is created without a restrictive 0600 mode"

# --- doctor check IDs ----------------------------------------------------
# The 23 original IDs plus the 5 ported from the VM doctor. The exact-count
# assert makes a rename fail instead of quietly registering a new ID.
k8s_doctor_ids="$(grep -oE 'K8S\.[A-Z_0-9]+\.[A-Z_0-9]+' "$K8S_SCRIPT" | sort -u)"
for id in \
    K8S.ACCESS.PUBLIC_ENDPOINTS K8S.ACCESS.ROLE_BINDING K8S.BACKUPS.FRESHNESS K8S.BACKUPS.INTEGRITY \
    K8S.CONFIG.BOOTSTRAP K8S.CONTEXT.CURRENT K8S.FUNDING.READY K8S.IDENTITY.CURRENT K8S.IMAGES.IMMUTABLE \
    K8S.KEYS.INTEGRITY K8S.L1_CONFIG.CONSISTENCY K8S.L1_CONFIG.METADATA K8S.MANAGER.TOPOLOGY \
    K8S.NAMESPACE.DISCOVERY K8S.NETWORK_POLICY.PRESENT K8S.PEERS.BOOTSTRAP K8S.PEERS.VISIBLE \
    K8S.RBAC.EFFECTIVE K8S.RELEASE.AVAILABLE K8S.RELEASE.INTEGRITY K8S.RPC.HEALTH K8S.RUNTIME.READY \
    K8S.RUNTIME.STATE K8S.SAFE.CONSOLE_ENV K8S.SAFE.DISCOVERY K8S.STATE.INTEGRITY K8S.STORAGE.PVC \
    K8S.WORKLOADS.DISCOVERY; do
    grep -Fqx "$id" <<<"$k8s_doctor_ids" || fail "the k8s doctor no longer emits $id"
done
[[ "$(grep -c . <<<"$k8s_doctor_ids")" -eq 28 ]] || \
    fail "the k8s doctor emits $(grep -c . <<<"$k8s_doctor_ids") named check IDs instead of 28; add it to the list above or restore the original ID"
# Each of the five ported checks must carry the evidence it was ported for, so a
# later edit cannot keep the ID while hollowing out what it measures. Scoped to
# doctor_k8s so a match elsewhere in the driver cannot satisfy these.
k8s_doctor_body="$(function_body "$K8S_SCRIPT" doctor_k8s)"
[[ -n "$k8s_doctor_body" ]] || fail "doctor_k8s function body could not be located in $K8S_SCRIPT"
# K8S.PEERS.BOOTSTRAP is the VM's eligibleBootstrapPeerCount: the intersection of
# the Info API's peers with the current Primary Network validator set.
grep -Fq 'info.peers' <<<"$k8s_doctor_body" || \
    fail "K8S.PEERS.BOOTSTRAP no longer reads the Info API peer list"
grep -Fq 'platform.getCurrentValidators' <<<"$k8s_doctor_body" || \
    fail "K8S.PEERS.BOOTSTRAP no longer intersects peers with the current Primary Network validator set"
# Both responses are hundreds of kilobytes on Fuji and larger on Mainnet, past
# MAX_ARG_STRLEN, so they must reach jq as files. Through argv the intersection
# fails on every real network and a healthy L1 is reported as having no bootstrap
# peers, which the two text pins above cannot see, so pin the transport too.
grep -Eq 'rpc_call /ext/info info\.peers .*>"\$TMP_DIR/doctor-info-peers\.json"' <<<"$k8s_doctor_body" || \
    fail "K8S.PEERS.BOOTSTRAP no longer writes the Info API peer response to a file"
grep -Eq 'rpc_call /ext/P platform\.getCurrentValidators .*>"\$TMP_DIR/doctor-primary-validators\.json"' <<<"$k8s_doctor_body" || \
    fail "K8S.PEERS.BOOTSTRAP no longer writes the Primary Network validator response to a file"
if grep -Eq -- '--argjson (peers|validators)|--arg (peers|validators)' <<<"$k8s_doctor_body"; then
    fail "K8S.PEERS.BOOTSTRAP passes an RPC response through argv again, which exceeds MAX_ARG_STRLEN on any real network"
fi
k8s_peers_write_line="$(grep -Fn 'rpc_call /ext/info info.peers' <<<"$k8s_doctor_body" | head -1 | cut -d: -f1)" || true
k8s_validators_write_line="$(grep -Fn 'rpc_call /ext/P platform.getCurrentValidators' <<<"$k8s_doctor_body" | head -1 | cut -d: -f1)" || true
k8s_peers_read_line="$(grep -Fn -- '--slurpfile peers' <<<"$k8s_doctor_body" | head -1 | cut -d: -f1)" || true
k8s_validators_read_line="$(grep -Fn -- '--slurpfile validators' <<<"$k8s_doctor_body" | head -1 | cut -d: -f1)" || true
[[ -n "$k8s_peers_write_line" && -n "$k8s_validators_write_line" && \
    -n "$k8s_peers_read_line" && -n "$k8s_validators_read_line" ]] || \
    fail "K8S.PEERS.BOOTSTRAP does not read both RPC responses with jq --slurpfile"
[[ "$k8s_peers_write_line" -lt "$k8s_peers_read_line" && \
    "$k8s_validators_write_line" -lt "$k8s_validators_read_line" ]] || \
    fail "K8S.PEERS.BOOTSTRAP intersects the peer and validator sets before both responses have been written"
grep -Fq '$peers[0].result.peers' <<<"$k8s_doctor_body" || \
    fail "K8S.PEERS.BOOTSTRAP does not read the slurped peer response, so the intersection is always empty"
grep -Fq '$validators[0].result.validators' <<<"$k8s_doctor_body" || \
    fail "K8S.PEERS.BOOTSTRAP does not read the slurped validator response, so the intersection is always empty"
# K8S.CONFIG.BOOTSTRAP: a loopback info-rpc-url is an operator port-forward that
# only exists while k8s-relayer-access runs, and must never be a bootstrap source.
grep -Fq 'is a loopback endpoint that only exists while an operator port-forward is running' <<<"$k8s_doctor_body" || \
    fail "K8S.CONFIG.BOOTSTRAP no longer flags a loopback info-rpc-url bootstrap source"
# K8S.SAFE.DISCOVERY / K8S.SAFE.CONSOLE_ENV.
grep -Fq 'discover_safe' <<<"$k8s_doctor_body" || \
    fail "K8S.SAFE.DISCOVERY no longer runs Safe discovery"
grep -Fq '.name == "SAFE_ADDRESS" or .name == "SAFE_TX_SERVICE_URL" or .name == "SAFE_UI_URL"' <<<"$k8s_doctor_body" || \
    fail "K8S.SAFE.CONSOLE_ENV no longer requires all three Safe console variables"
grep -Fq '/api/v1/about/' <<<"$k8s_doctor_body" || \
    fail "K8S.SAFE.CONSOLE_ENV no longer probes the configured Safe Transaction Service"
# K8S.BACKUPS.INTEGRITY verifies the newest retained archive against the sha256
# its own manifest records.
grep -Fq '.archive.sha256' <<<"$k8s_doctor_body" || \
    fail "K8S.BACKUPS.INTEGRITY no longer compares the retained archive against its manifest checksum"
grep -Fq 'avalanche-deploy-relayer-backup' <<<"$k8s_doctor_body" || \
    fail "K8S.BACKUPS.INTEGRITY no longer validates the retained manifest structurally"
# K8S.STATE.INTEGRITY must check the rolling hot backup, never the live database
# the running daemon holds open.
grep -Fq -- '--check-db /data/backups/relayer.db.bak' <<<"$k8s_doctor_body" || \
    fail "K8S.STATE.INTEGRITY no longer verifies the rolling hot backup"
grep -Fq 'the active daemon holds the live bbolt lock' <<<"$k8s_doctor_body" || \
    fail "K8S.STATE.INTEGRITY no longer explains that the live bbolt lock blocks direct verification"
grep -Fq -- '--check-db /data/relayer.db' <<<"$k8s_doctor_body" && \
    fail "K8S.STATE.INTEGRITY checks the live bbolt database the daemon holds open"

# --- doctor scope: what a reapply may repair, and what always blocks -----
# make k8s-relayer gates itself on doctor_k8s install, so a check the install itself
# repairs must warn at install scope: as a blocker its only remediation is the
# command it prevents, and the install is unrepairable by its own instructions. The
# same checks must stay blockers at operations scope, where nothing is about to
# repair them. Severities are read from the branch that produces each result,
# because a WARN or a FAIL merely existing somewhere in the function proves nothing
# about the scope that reaches it.
doctor_result_conditions() {
    awk -v marker="doctor_result $1 $2" '
        /^[[:space:]]*(if|elif) / { cond = $0; next }
        /^[[:space:]]*else$/ { cond = "else"; next }
        index($0, marker) { print cond }
    ' <<<"$k8s_doctor_body"
}
for id in K8S.RUNTIME.READY K8S.RELEASE.INTEGRITY K8S.IMAGES.IMMUTABLE K8S.FUNDING.READY K8S.SAFE.CONSOLE_ENV; do
    doctor_warn_conditions="$(doctor_result_conditions WARN "$id")"
    doctor_fail_conditions="$(doctor_result_conditions FAIL "$id")"
    grep -Fq 'doctor_scope" == install' <<<"$doctor_warn_conditions" || \
        fail "$id has no install-scope WARN branch, so make k8s-relayer blocks on a check that only the install it gates can repair"
    [[ -n "$doctor_fail_conditions" ]] || \
        fail "$id is never a blocker, so make k8s-relayer-doctor exits 0 on a Relayer that cannot operate"
    grep -vFq 'doctor_scope" == install' <<<"$doctor_fail_conditions" || \
        fail "$id only blocks at install scope, so operations diagnostics no longer report it"
done
# The severity inversion this corrected: a Safe-owned console that lost SAFE_ADDRESS
# or its Transaction Service URL cannot propose any validator change, yet the
# missing-variable branch warned at every scope and the doctor exited 0.
k8s_safe_env_fail_conditions="$(doctor_result_conditions FAIL \
    'K8S.SAFE.CONSOLE_ENV "installed Safe-owned console container is missing')"
[[ -n "$k8s_safe_env_fail_conditions" ]] || \
    fail "K8S.SAFE.CONSOLE_ENV does not block when an installed Safe-owned console is missing its Safe integration variables"
grep -vFq 'doctor_scope" == install' <<<"$k8s_safe_env_fail_conditions" || \
    fail "K8S.SAFE.CONSOLE_ENV only reports missing Safe console variables at install scope"
# K8S.RPC.HEALTH is the one preflight blocker that must not be scope-dependent: the
# installer runs the same preflight seconds later and dies on it anyway.
k8s_rpc_health_conditions="$(doctor_result_conditions FAIL K8S.RPC.HEALTH)"
[[ -n "$k8s_rpc_health_conditions" ]] || fail "K8S.RPC.HEALTH is no longer a blocker"
grep -Fq 'doctor_scope' <<<"$k8s_rpc_health_conditions" && \
    fail "K8S.RPC.HEALTH became scope-dependent, so an install proceeds past a preflight it cannot pass"
[[ -z "$(doctor_result_conditions WARN K8S.RPC.HEALTH)" ]] || \
    fail "K8S.RPC.HEALTH can now warn instead of blocking"
# K8S.CONFIG.BOOTSTRAP warns at both scopes by design; only its remediation is
# scope-aware, because at install scope the reapply itself is the repair.
grep -Fq 'this install/reapply will render the managed in-cluster Info API' <<<"$k8s_doctor_body" || \
    fail "K8S.CONFIG.BOOTSTRAP no longer tells an installing operator that the reapply is the repair"
# The FAIL that replaces the installer's own output must carry the captured cause:
# without it a missing StorageClass or a renounced PoAManager owner is reported as
# an unhealthy RPC, remediated by running the installer this blocker prevents.
grep -Fq '2>"$preflight_log"' <<<"$k8s_doctor_body" || \
    fail "the doctor discards the preflight's stderr, so K8S.RPC.HEALTH cannot report why the preflight failed"
grep -Fq 'preflight failed${preflight_reason:+: $preflight_reason}' <<<"$k8s_doctor_body" || \
    fail "K8S.RPC.HEALTH no longer carries the captured preflight cause into its summary"
if grep -Fq 'run make k8s-relayer for detailed preflight output' <<<"$k8s_doctor_body"; then
    fail "K8S.RPC.HEALTH remediates by running the installer its own blocker prevents"
fi

# --- release tag validation: one pattern at every gate -------------------
# A secondary check stricter than main()'s admitted the tag, downloaded the release
# or scaled the workload down, and only then rejected it. All five sites must accept
# exactly what main() accepts.
[[ "$(grep -Fc '^v[0-9A-Za-z][0-9A-Za-z.+-]*$' "$K8S_SCRIPT")" -eq 5 ]] || \
    fail "the k8s driver validates RELAYER_VERSION with something other than main()'s pattern at all five gates"
if grep -Fq '0-9A-Za-z._-' "$K8S_SCRIPT"; then
    fail "the k8s driver reintroduced a secondary RELAYER_VERSION pattern that rejects tags main() accepts"
fi

# --- protocol privacy: a truthful refusal, not an impossible remediation --
# A validatorOnly L1 never exposes its validator as an RPC peer, so telling the
# operator to reconfigure the L1 and wait for peering describes a wait that cannot
# end. This path does not support protocol-private L1s; the VM path does.
require_file_text "$K8S_SCRIPT" 'validatorOnly'
require_file_text "$K8S_SCRIPT" 'the Kubernetes Relayer path does not support protocol-private L1s'
if grep -Fq 'rerun make k8s-l1-configure and wait for peering' "$K8S_SCRIPT"; then
    fail "the peer-visibility refusal still remediates by waiting for peering, which never completes on a protocol-private L1"
fi

echo "Relayer static acceptance checks passed"
