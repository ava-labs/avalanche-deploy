#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/shared/relayer-doctor-lib.sh
source "$ROOT_DIR/scripts/shared/relayer-doctor-lib.sh"
ACTION="${1:-install}"
PINNED_RELAYER_VERSION="v0.0.0-transfer-required"
RELAYER_VERSION="${RELAYER_VERSION:-$PINNED_RELAYER_VERSION}"
L1_ENV="$ROOT_DIR/l1.env"
RELAYER_REPOSITORY="${RELAYER_DEVELOPMENT_REPOSITORY:-ava-labs/validator-lifecycle-relayer}"
RELAYER_DEVELOPMENT_TOKEN="${RELAYER_DEVELOPMENT_TOKEN:-}"

WORK_DIR=""
CLOUD=""
INVENTORY_FILE=""
INVENTORY_SUMMARY=""
TARGET_NAME=""
TARGET_HOST=""
VALIDATOR_PRIVATE_IPS=""
METADATA_FILE=""
DISCOVERY_FILE=""
RELEASE_BINARY=""
RELEASE_SETUP=""
RELEASE_RESTORE=""
CONSOLE_IMAGE=""
INFO_RPC_URL=""

usage() {
  cat >&2 <<'EOF'
usage: scripts/l1/relayer.sh [prereqs|doctor|install|access|status|logs|backup|restore|upgrade|remove]

All infrastructure and L1 metadata are discovered from l1.env, Terraform state,
and the matching Ansible inventory. RELAYER_VERSION is the only advanced
override. Set PURGE=true with remove to permanently delete retained material.
EOF
  exit 2
}

doctor_command() {
  local command_name="$1" package_hint="$2" id
  id="$(printf '%s' "$command_name" | tr '[:lower:]-' '[:upper:]_')"
  if command -v "$command_name" >/dev/null 2>&1; then
    doctor_result PASS "VM.TOOL.$id" "$command_name is available" none
  else
    doctor_result FAIL "VM.TOOL.$id" "$command_name is missing" "run make relayer-prereqs or install $package_hint"
  fi
}

doctor_safe_integration() {
  local discovery_file="$1"
  local owner_type safe_services_detected safe_service_state safe_transaction_status
  owner_type="$(jq -r '.ownerType // empty' "$discovery_file")"
  safe_services_detected="$(jq -r '.safeServicesDetected // false' "$discovery_file")"
  safe_service_state="$(jq -r '.safeServiceState // "unknown"' "$discovery_file")"
  safe_transaction_status="$(jq -r '.safeTransactionServiceStatus // 0' "$discovery_file")"

  if [[ "$owner_type" == safe && "$safe_services_detected" != true ]]; then
    doctor_result FAIL VM.SAFE.DISCOVERY \
      "PoAManager owner is a Safe, but safe.service or its Transaction Service is not healthy (unit=$safe_service_state, HTTP=$safe_transaction_status)" \
      "run make safe on rpc[0], verify http://127.0.0.1:8001/api/v1/about/ returns HTTP 200, then rerun make relayer-doctor"
  elif [[ "$owner_type" == safe ]]; then
    doctor_result PASS VM.SAFE.DISCOVERY \
      "PoAManager owner is a Safe and the local Safe service integration is healthy" none
  elif [[ "$owner_type" == eoa ]]; then
    doctor_result PASS VM.SAFE.DISCOVERY "PoAManager owner is a supported EOA" none
  else
    doctor_result FAIL VM.SAFE.DISCOVERY \
      "PoAManager owner type was not reported by discovery" \
      "rerun the Ansible discovery playbook and repair owner detection"
  fi
}

doctor_safe_console_environment() {
  local discovery_file="$1"
  local doctor_scope="$2"
  local owner_type daemon_installed console_installed console_env_present console_env_complete
  owner_type="$(jq -r '.ownerType // empty' "$discovery_file")"
  daemon_installed="$(jq -r '.daemonInstalled // false' "$discovery_file")"
  console_installed="$(jq -r '.consoleInstalled // false' "$discovery_file")"
  console_env_present="$(jq -r '.safeConsoleEnvPresent // false' "$discovery_file")"
  console_env_complete="$(jq -r '.safeConsoleEnvComplete // false' "$discovery_file")"

  if [[ "$owner_type" != safe ]]; then
    doctor_result SKIP VM.SAFE.CONSOLE_ENV \
      "Safe console variables do not apply to an EOA-owned PoAManager" none
  elif [[ "$daemon_installed" != true && "$console_installed" != true ]]; then
    doctor_result SKIP VM.SAFE.CONSOLE_ENV \
      "Safe console variables do not apply while the Relayer workload is absent" \
      "the installer will render SAFE_TX_SERVICE_URL, SAFE_UI_URL, and SAFE_ADDRESS"
  elif [[ "$console_env_present" == true && "$console_env_complete" == true ]]; then
    doctor_result PASS VM.SAFE.CONSOLE_ENV \
      "installed console.env contains all required Safe integration keys" none
  elif [[ "$doctor_scope" == install ]]; then
    doctor_result WARN VM.SAFE.CONSOLE_ENV \
      "installed Safe-owned Relayer console.env is absent or missing required Safe integration keys" \
      "this install/reapply will render SAFE_TX_SERVICE_URL, SAFE_UI_URL, and SAFE_ADDRESS"
  else
    doctor_result FAIL VM.SAFE.CONSOLE_ENV \
      "installed Safe-owned Relayer console.env is absent or missing required Safe integration keys" \
      "run make relayer to reapply the managed Safe integration"
  fi
}

relayer_remote_check() {
  "$@"
}

doctor_state_integrity() {
  local runtime_ready="$1"
  shift
  local -a ansible_prefix=("$@")

  if [[ "$runtime_ready" == true ]] && \
    relayer_remote_check "${ansible_prefix[@]}" -m ansible.builtin.command -a '/usr/bin/test -f /var/backups/relayerd/relayer.db.bak' >/dev/null 2>&1; then
    if relayer_remote_check "${ansible_prefix[@]}" -m ansible.builtin.command -a '/usr/local/bin/relayer-restore --check-db /var/backups/relayerd/relayer.db.bak' >/dev/null 2>&1; then
      doctor_result PASS VM.STATE.INTEGRITY "the daemon-opened bbolt state has a structurally valid rolling hot backup" none
    else
      doctor_result FAIL VM.STATE.INTEGRITY "the rolling bbolt hot backup failed its read-only integrity check" "inspect relayerd backup logs and create a validated make relayer-backup before lifecycle operations"
    fi
  elif [[ "$runtime_ready" == true ]]; then
    doctor_result WARN VM.STATE.INTEGRITY "relayerd opened the live database but its first rolling hot backup is not available yet" "wait one five-minute backup interval, then rerun doctor"
  elif relayer_remote_check "${ansible_prefix[@]}" -m ansible.builtin.command -a '/usr/bin/systemctl is-active --quiet relayerd.service' >/dev/null 2>&1; then
    doctor_result WARN VM.STATE.INTEGRITY "the active daemon holds the live bbolt lock and is not ready enough to verify its rolling backup" "repair runtime readiness, wait for a hot backup, then rerun doctor"
  elif relayer_remote_check "${ansible_prefix[@]}" -m ansible.builtin.command -a '/usr/local/bin/relayer-restore --check-db /var/lib/relayerd/relayer.db' >/dev/null 2>&1; then
    doctor_result PASS VM.STATE.INTEGRITY "offline bbolt state passes a read-only integrity check" none
  else
    doctor_result FAIL VM.STATE.INTEGRITY "bbolt state integrity check failed" "restore a validated make relayer-backup archive"
  fi
}

doctor_vm() {
  local doctor_scope="${1:-operations}"
  case "$doctor_scope" in
    operations|install) ;;
    *) die "internal error: unsupported Relayer doctor scope '$doctor_scope'" ;;
  esac
  DOCTOR_FAILURES=0
  DOCTOR_WARNINGS=0
  if [[ -n "${RELAYER_DOCTOR_FIXTURE:-}" ]]; then
    doctor_run_fixture "$RELAYER_DOCTOR_FIXTURE"
    return
  fi

  doctor_command terraform Terraform
  doctor_command ansible Ansible
  doctor_command ansible-playbook Ansible
  doctor_command ansible-inventory Ansible
  doctor_command jq jq
  doctor_command python3 Python
  doctor_command curl curl
  doctor_command ssh OpenSSH

  if command -v terraform >/dev/null 2>&1; then
    local terraform_version
    terraform_version="$(terraform version -json 2>/dev/null | jq -r '.terraform_version // empty' 2>/dev/null || true)"
    if [[ "$terraform_version" =~ ^([0-9]+)\.([0-9]+)\. ]] && \
      { ((BASH_REMATCH[1] > 1)) || ((BASH_REMATCH[1] == 1 && BASH_REMATCH[2] >= 5)); }; then
      doctor_result PASS VM.TOOL.TERRAFORM_VERSION "Terraform $terraform_version satisfies the minimum 1.5 version" none
    else
      doctor_result FAIL VM.TOOL.TERRAFORM_VERSION "Terraform version '$terraform_version' is unsupported" "upgrade Terraform to version 1.5 or newer"
    fi
  else
    doctor_result SKIP VM.TOOL.TERRAFORM_VERSION "Terraform version was not checked because Terraform is missing" "run make relayer-prereqs"
  fi

  if [[ -f "$L1_ENV" ]]; then
    doctor_result PASS VM.L1_ENV.PRESENT "generated l1.env is present" none
    local env_age now modified
    now="$(date +%s)"
    if modified="$(stat -f %m "$L1_ENV" 2>/dev/null || stat -c %Y "$L1_ENV" 2>/dev/null)"; then
      env_age=$(((now - modified) / 86400))
      if ((env_age > 30)); then
        doctor_result WARN VM.L1_ENV.AGE "l1.env is $env_age days old; live state will still be cross-checked" "confirm this checkout is the active Avalanche Deploy workspace"
      else
        doctor_result PASS VM.L1_ENV.AGE "l1.env age is $env_age days" none
      fi
    else
      doctor_result WARN VM.L1_ENV.AGE "l1.env age could not be determined" "inspect the file timestamp manually"
    fi
    local missing_metadata="" key
    for key in NETWORK SUBNET_ID CHAIN_ID EVM_CHAIN_ID CHAIN_NAME POA_MANAGER VALIDATOR_MANAGER_PROXY; do
      grep -Eq "^${key}=.+" "$L1_ENV" || missing_metadata="${missing_metadata:+$missing_metadata,}$key"
    done
    if [[ -z "$missing_metadata" ]]; then
      doctor_result PASS VM.L1_ENV.METADATA "required managed-L1 metadata keys are present" none
    else
      doctor_result FAIL VM.L1_ENV.METADATA "l1.env is missing required keys: $missing_metadata" "rerun L1 creation and PoAManager initialization so l1.env is regenerated"
    fi
  else
    doctor_result FAIL VM.L1_ENV.PRESENT "generated l1.env is missing" "create and initialize the Avalanche Deploy L1 before installing the Relayer"
    doctor_result SKIP VM.L1_ENV.AGE "l1.env age was not checked" "restore l1.env"
    doctor_result SKIP VM.L1_ENV.METADATA "l1.env metadata was not checked" "restore l1.env"
  fi

  local -a states=()
  local cloud terraform_dir inventory rpc_output
  if command -v terraform >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    for cloud in aws gcp azure; do
      terraform_dir="$ROOT_DIR/terraform/l1/$cloud"
      if rpc_output="$(terraform -chdir="$terraform_dir" output -json rpc_ips 2>/dev/null)" && \
        jq -e 'type == "array" and length > 0' >/dev/null <<<"$rpc_output"; then
        states+=("$cloud")
      fi
    done
  fi
  if ((${#states[@]} == 1)); then
    CLOUD="${states[0]}"
    inventory="$ROOT_DIR/ansible/inventory/${CLOUD}_hosts"
    doctor_result PASS VM.TERRAFORM.STATE "exactly one accessible L1 state was found: $CLOUD" none
    if [[ -f "$inventory" ]]; then
      INVENTORY_FILE="$inventory"
      if command -v ansible-inventory >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 && \
        (discover_infrastructure) >/dev/null 2>&1; then
        doctor_result PASS VM.INVENTORY.MATCH "Terraform RPC/validator outputs match ansible/inventory/${CLOUD}_hosts" none
      else
        doctor_result FAIL VM.INVENTORY.MATCH "$CLOUD state and ansible/inventory/${CLOUD}_hosts could not be matched exactly" "regenerate the inventory from the active $CLOUD Terraform apply and verify rpc/validator host outputs"
      fi
    else
      doctor_result FAIL VM.INVENTORY.MATCH "$CLOUD state is accessible but ansible/inventory/${CLOUD}_hosts is missing" "regenerate the inventory from the active $CLOUD Terraform apply"
    fi
  elif ((${#states[@]} == 0)); then
    doctor_result FAIL VM.TERRAFORM.STATE "no accessible AWS, GCP, or Azure L1 state was found" "initialize and apply exactly one terraform/l1/<cloud> workspace and verify backend credentials"
    doctor_result SKIP VM.INVENTORY.MATCH "inventory consistency was not checked without one active state" "restore one matching inventory"
  else
    doctor_result FAIL VM.TERRAFORM.STATE "multiple accessible L1 states were found: ${states[*]}" "retain only the intended active Terraform workspace state in this checkout"
    doctor_result SKIP VM.INVENTORY.MATCH "inventory consistency is ambiguous with multiple states" "select one active state"
  fi

  if [[ -n "$INVENTORY_FILE" ]] && command -v ansible >/dev/null 2>&1; then
    if ANSIBLE_CONFIG="$ROOT_DIR/ansible/ansible.cfg" ansible -i "$INVENTORY_FILE" 'rpc[0]' -m ansible.builtin.ping >/dev/null 2>&1; then
      doctor_result PASS VM.ACCESS.SSH "Ansible can reach rpc[0] over SSH" none
    else
      doctor_result FAIL VM.ACCESS.SSH "Ansible cannot reach rpc[0] over SSH" "repair inventory host, user, key, port, and network access, then rerun make relayer-doctor"
    fi
    if ANSIBLE_CONFIG="$ROOT_DIR/ansible/ansible.cfg" ansible -i "$INVENTORY_FILE" 'rpc[0]' -b -m ansible.builtin.command -a true >/dev/null 2>&1; then
      doctor_result PASS VM.ACCESS.SUDO "the deployment administrator can use sudo on rpc[0]" none
    else
      doctor_result FAIL VM.ACCESS.SUDO "passwordless Ansible sudo is unavailable on rpc[0]" "grant the deployment administrator the same become access used by Avalanche Deploy"
    fi
  else
    doctor_result SKIP VM.ACCESS.SSH "SSH was not checked because inventory or Ansible is unavailable" "repair the earlier tool/state checks"
    doctor_result SKIP VM.ACCESS.SUDO "sudo was not checked because inventory or Ansible is unavailable" "repair the earlier tool/state checks"
  fi

  local preflight_ok=false
  if [[ -n "$INVENTORY_FILE" && -f "$L1_ENV" ]] && command -v ansible-playbook >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    ensure_work_dir
    DISCOVERY_FILE="$WORK_DIR/discovery.json"
    if (run_preflight false) >/dev/null 2>&1; then
      preflight_ok=true
      doctor_result PASS VM.RPC.HEALTH "rpc[0] matches the managed network, subnet, blockchain, and EVM chain" none
      doctor_result PASS VM.PEERS.VISIBLE "rpc[0] sees every deployed validator peer" none
      local eligible_bootstrap_count bootstrap_info_url
      eligible_bootstrap_count="$(jq -r '.eligibleBootstrapPeerCount // 0' "$DISCOVERY_FILE")"
      bootstrap_info_url="$(jq -r '.infoRpcUrl // empty' "$DISCOVERY_FILE")"
      if [[ "$eligible_bootstrap_count" =~ ^[0-9]+$ ]] && ((eligible_bootstrap_count > 0)); then
        doctor_result PASS VM.PEERS.BOOTSTRAP \
          "$bootstrap_info_url exposes $eligible_bootstrap_count current Primary Network bootstrap peer(s)" none
      else
        doctor_result FAIL VM.PEERS.BOOTSTRAP \
          "$bootstrap_info_url exposes no peers that are current Primary Network validators" \
          "restore access to the managed network Info API and confirm rpc[0] can reach Primary validator P2P endpoints"
      fi
      doctor_result PASS VM.MANAGER.TOPOLOGY "official PoAManager and initialized owned ValidatorManager topology verified" none
      doctor_safe_integration "$DISCOVERY_FILE"
    else
      doctor_result FAIL VM.PREFLIGHT.REMOTE "remote RPC, peer, topology, or retained-state preflight failed" "run ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ${INVENTORY_FILE#"$ROOT_DIR/"} ansible/playbooks/l1/discover-relayer.yml with the generated discovery variables, or rerun make relayer for detailed output"
      doctor_result SKIP VM.RPC.HEALTH "RPC health was not independently confirmed" "repair the remote preflight"
      doctor_result SKIP VM.PEERS.VISIBLE "validator peer visibility was not independently confirmed" "repair RPC-to-validator peering"
      doctor_result SKIP VM.PEERS.BOOTSTRAP "Primary Network bootstrap eligibility was not independently confirmed" "repair the remote preflight"
      doctor_result SKIP VM.MANAGER.TOPOLOGY "manager topology was not independently confirmed" "verify official PoAManager ownership and initialization"
      doctor_result SKIP VM.SAFE.DISCOVERY "EOA/Safe ownership was not independently confirmed" "repair the manager topology preflight"
    fi
  else
    doctor_result SKIP VM.PREFLIGHT.REMOTE "remote preflight prerequisites are incomplete" "repair the earlier tool, l1.env, and state checks"
    doctor_result SKIP VM.RPC.HEALTH "RPC health was not checked" "repair the remote preflight prerequisites"
    doctor_result SKIP VM.PEERS.VISIBLE "validator peer visibility was not checked" "repair the remote preflight prerequisites"
    doctor_result SKIP VM.PEERS.BOOTSTRAP "Primary Network bootstrap eligibility was not checked" "repair the remote preflight prerequisites"
    doctor_result SKIP VM.MANAGER.TOPOLOGY "manager topology was not checked" "repair the remote preflight prerequisites"
    doctor_result SKIP VM.SAFE.DISCOVERY "EOA/Safe ownership was not checked" "repair the remote preflight prerequisites"
  fi

  if [[ "$preflight_ok" == true && -f "$DISCOVERY_FILE" ]]; then
    local architecture daemon_installed console_installed keystore_exists restore_installed release_metadata_exists
    architecture="$(jq -r '.architecture // empty' "$DISCOVERY_FILE")"
    case "$architecture" in
      x86_64|amd64|aarch64|arm64) doctor_result PASS VM.TARGET.ARCHITECTURE "rpc[0] architecture $architecture has a published release target" none ;;
      *) doctor_result FAIL VM.TARGET.ARCHITECTURE "rpc[0] architecture '$architecture' is unsupported" "move rpc[0] to AMD64 or ARM64" ;;
    esac
    local memory_mb disk_available min_disk_bytes=10737418240
    memory_mb="$(jq -r '.memoryMb // 0' "$DISCOVERY_FILE")"
    disk_available="$(jq -r '.rootDiskAvailableBytes // 0' "$DISCOVERY_FILE")"
    if [[ "$memory_mb" =~ ^[0-9]+$ && "$disk_available" =~ ^[0-9]+$ ]] && \
      ((memory_mb >= 2048 && disk_available >= min_disk_bytes)); then
      doctor_result PASS VM.TARGET.CAPACITY "rpc[0] has ${memory_mb} MiB memory and ${disk_available} bytes free on /" none
    else
      doctor_result FAIL VM.TARGET.CAPACITY "rpc[0] has ${memory_mb} MiB memory and ${disk_available} bytes free on /" "provide at least 2048 MiB memory and 10 GiB free root-disk capacity on rpc[0]"
    fi
    daemon_installed="$(jq -r '.daemonInstalled' "$DISCOVERY_FILE")"
    console_installed="$(jq -r '.consoleInstalled' "$DISCOVERY_FILE")"
    keystore_exists="$(jq -r '.keystoreExists' "$DISCOVERY_FILE")"
    restore_installed="$(jq -r '.restoreUtilityInstalled' "$DISCOVERY_FILE")"
    release_metadata_exists="$(jq -r '.releaseMetadataExists' "$DISCOVERY_FILE")"
    if [[ "$daemon_installed" == true && "$console_installed" == true && "$keystore_exists" == true && \
      "$restore_installed" == true && "$release_metadata_exists" == true ]]; then
      doctor_result PASS VM.INSTALLATION.STATE "Relayer is installed with persistent key material" none
    elif [[ "$daemon_installed" == false && "$console_installed" == false && "$keystore_exists" == false ]]; then
      doctor_result PASS VM.INSTALLATION.STATE "Relayer is not installed and the target is ready for a fresh install" none
    elif [[ "$daemon_installed" == false && "$console_installed" == false && "$keystore_exists" == true ]]; then
      doctor_result PASS VM.INSTALLATION.STATE "Relayer workload is removed and retained state is ready for reinstall" none
    else
      doctor_result FAIL VM.INSTALLATION.STATE "Relayer installation is partial or inconsistent" "restore matching state/config/keys from a retained backup or run make relayer-remove PURGE=true only after separate recovery approval"
    fi
    doctor_safe_console_environment "$DISCOVERY_FILE" "$doctor_scope"

    local configured_info_rpc_url selected_info_rpc_url
    configured_info_rpc_url="$(jq -r '.configuredInfoRpcUrl // empty' "$DISCOVERY_FILE")"
    selected_info_rpc_url="$(jq -r '.infoRpcUrl // empty' "$DISCOVERY_FILE")"
    if [[ "$daemon_installed" == true && "$configured_info_rpc_url" != "$selected_info_rpc_url" ]]; then
      if [[ "$doctor_scope" == install ]]; then
        doctor_result WARN VM.CONFIG.BOOTSTRAP \
          "installed info-rpc-url differs from the managed $selected_info_rpc_url bootstrap source" \
          "this install/reapply will render the managed network bootstrap source"
      else
        doctor_result FAIL VM.CONFIG.BOOTSTRAP \
          "installed info-rpc-url differs from the managed $selected_info_rpc_url bootstrap source" \
          "run make relayer to reapply the managed configuration"
      fi
    elif [[ "$daemon_installed" == true ]]; then
      doctor_result PASS VM.CONFIG.BOOTSTRAP "installed info-rpc-url matches $selected_info_rpc_url" none
    else
      doctor_result SKIP VM.CONFIG.BOOTSTRAP "installed bootstrap configuration does not apply while the workload is absent" "the installer will render the managed network Info API"
    fi

    local release_arch version_without_v release_url release_base published_console_image=""
    case "$architecture" in x86_64|amd64) release_arch=amd64 ;; *) release_arch=arm64 ;; esac
    version_without_v="${RELAYER_VERSION#v}"
    release_url="https://github.com/$RELAYER_REPOSITORY/releases/download/$RELAYER_VERSION/relayer_${version_without_v}_linux_${release_arch}.tar.gz"
    release_base="https://github.com/$RELAYER_REPOSITORY/releases/download/$RELAYER_VERSION"
    published_console_image="$(release_curl -fsSL --retry 1 "$release_base/relayer-console-image.txt" 2>/dev/null | tr -d '[:space:]' || true)"
    if release_curl -fsIL --retry 1 "$release_url" >/dev/null 2>&1 && \
      release_curl -fsSL --retry 1 "$release_base/checksums.txt" >/dev/null 2>&1 && \
      [[ "$published_console_image" =~ ^ghcr\.io/.+@sha256:[0-9a-f]{64}$ ]]; then
      doctor_result PASS VM.RELEASE.AVAILABLE "$RELAYER_VERSION archive, checksums, and immutable console image are available for $release_arch" none
    else
      doctor_result FAIL VM.RELEASE.AVAILABLE "$RELAYER_VERSION release archive or checksums are unavailable for $release_arch" "publish the tested public Relayer release or set an approved development repository/version override"
    fi

    if [[ "$daemon_installed" == true ]]; then
      local ansible_prefix
      ansible_prefix=(env ANSIBLE_CONFIG="$ROOT_DIR/ansible/ansible.cfg" ansible -i "$INVENTORY_FILE" 'rpc[0]' -b)
      local installed_version daemon_sha recorded_version recorded_sha recorded_console
      installed_version="$(jq -r '.installedVersion // empty' "$DISCOVERY_FILE")"
      daemon_sha="$(jq -r '.daemonSha256 // empty' "$DISCOVERY_FILE")"
      recorded_version="$(jq -r '.recordedRelease.version // empty' "$DISCOVERY_FILE")"
      recorded_sha="$(jq -r '.recordedRelease.daemonSha256 // empty' "$DISCOVERY_FILE")"
      recorded_console="$(jq -r '.recordedRelease.consoleImage // empty' "$DISCOVERY_FILE")"
      if [[ "$installed_version" == "$RELAYER_VERSION" && "$recorded_version" == "$RELAYER_VERSION" && \
        "$daemon_sha" =~ ^[0-9a-f]{64}$ && "$daemon_sha" == "$recorded_sha" && \
        "$recorded_console" =~ ^ghcr\.io/.+@sha256:[0-9a-f]{64}$ && \
        -n "$published_console_image" && "$recorded_console" == "$published_console_image" ]]; then
        doctor_result PASS VM.RELEASE.INTEGRITY "installed version, daemon checksum, and console digest match recorded and published release metadata" none
      elif [[ "$doctor_scope" == install ]]; then
        doctor_result WARN VM.RELEASE.INTEGRITY "installed release metadata, daemon checksum, version, or console digest has drifted" "this install/reapply will restore the verified pinned artifacts"
      else
        doctor_result FAIL VM.RELEASE.INTEGRITY "installed release metadata, daemon checksum, version, or console digest has drifted" "run make relayer-upgrade RELAYER_VERSION=$RELAYER_VERSION to reapply verified artifacts"
      fi
      local runtime_ready=false
      if "${ansible_prefix[@]}" -m ansible.builtin.uri -a 'url=http://127.0.0.1:8081/ready status_code=200' >/dev/null 2>&1; then
        runtime_ready=true
        doctor_result PASS VM.RUNTIME.READY "relayerd readiness endpoint is healthy" none
      elif [[ "$doctor_scope" == install ]]; then
        doctor_result WARN VM.RUNTIME.READY "relayerd is installed but not ready" "this install/reapply will render configuration and restart the runtime"
      else
        doctor_result FAIL VM.RUNTIME.READY "relayerd is installed but not ready" "inspect make relayer-logs and restore or repair the runtime before validator operations"
      fi
      if "${ansible_prefix[@]}" -m ansible.builtin.command -a '/usr/local/bin/relayer-restore --check-keystore /var/lib/relayerd/keystore.json --password-file /etc/relayerd/secrets/keystore-password' >/dev/null 2>&1; then
        doctor_result PASS VM.KEYS.INTEGRITY "encrypted keystore decrypts with its retained credential" none
      else
        doctor_result FAIL VM.KEYS.INTEGRITY "encrypted keystore integrity could not be verified" "restore keystore.json and keystore-password from the same backup"
      fi
      doctor_state_integrity "$runtime_ready" "${ansible_prefix[@]}"
      ensure_work_dir
      local funding_status_file="$WORK_DIR/funding-status.txt"
      if "${ansible_prefix[@]}" -m ansible.builtin.uri -a 'url=http://127.0.0.1:8081/keys status_code=200 return_content=true' >"$funding_status_file" 2>/dev/null; then
        if grep -q 'fundedFloat.*true' "$funding_status_file" && grep -q 'fundedGas.*true' "$funding_status_file"; then
          doctor_result PASS VM.FUNDING.READY "P-Chain float and L1 gas addresses meet daemon funding thresholds" none
        elif [[ "$doctor_scope" == install ]]; then
          doctor_result WARN VM.FUNDING.READY "one or both public relayer funding addresses are below threshold" "complete the install/reapply, then fund the addresses printed by make relayer-status"
        else
          doctor_result FAIL VM.FUNDING.READY "one or both public relayer funding addresses are below threshold" "fund the P-Chain float and L1 EVM gas addresses printed by make relayer-status"
        fi
      elif [[ "$doctor_scope" == install ]]; then
        doctor_result WARN VM.FUNDING.READY "public funding status could not be read from the unhealthy runtime" "complete the install/reapply, then fund the addresses printed by make relayer-status"
      else
        doctor_result FAIL VM.FUNDING.READY "public funding status could not be read" "repair relayerd readiness and rerun doctor"
      fi
      local listeners_file="$WORK_DIR/listeners.txt"
      if "${ansible_prefix[@]}" -m ansible.builtin.shell -a "public=\$(ss -ltnH | awk '\$4 ~ /:(8081|3080)$/ {print \$4}' | grep -Ev '^(127\\.0\\.0\\.1|\\[::1\\]):' || true); printf '%s\\n' \"\$public\"" >"$listeners_file" 2>/dev/null; then
        if grep -Eq '(^|[[:space:]])([^[:space:]]+:)?(8081|3080)($|[[:space:]])' "$listeners_file"; then
          doctor_result FAIL VM.LISTENERS.LOOPBACK "a Relayer listener is bound beyond loopback" "set daemon and console listeners to 127.0.0.1 and restart"
        else
          doctor_result PASS VM.LISTENERS.LOOPBACK "daemon and console listeners are loopback-only" none
        fi
      else
        doctor_result WARN VM.LISTENERS.LOOPBACK "listener binding could not be inspected" "run sudo ss -ltnp on rpc[0] and confirm ports 8081/3080 are loopback-only"
      fi
      local latest_backup_mtime latest_backup_sha manifest_sha now backup_age
      latest_backup_mtime="$(jq -r '.latestBackupMtime // 0 | floor' "$DISCOVERY_FILE")"
      latest_backup_sha="$(jq -r '.latestBackupSha256 // empty' "$DISCOVERY_FILE")"
      manifest_sha="$(jq -r '.latestBackupManifest.archive.sha256 // empty' "$DISCOVERY_FILE")"
      if [[ "$latest_backup_mtime" =~ ^[0-9]+$ ]] && ((latest_backup_mtime > 0)); then
        now="$(date +%s)"
        backup_age=$(((now - latest_backup_mtime) / 86400))
        if [[ "$latest_backup_sha" =~ ^[0-9a-f]{64}$ && "$latest_backup_sha" == "$manifest_sha" ]]; then
          if ((backup_age > 7)); then
            doctor_result WARN VM.BACKUPS.INTEGRITY "latest retained backup is checksum-valid but $backup_age days old" "run make relayer-backup before lifecycle changes"
          else
            doctor_result PASS VM.BACKUPS.INTEGRITY "latest retained backup is checksum-valid and $backup_age days old" none
          fi
        else
          doctor_result FAIL VM.BACKUPS.INTEGRITY "latest retained backup archive and manifest checksum do not match" "run make relayer-backup and retain the new archive/manifest pair"
        fi
      else
        doctor_result WARN VM.BACKUPS.INTEGRITY "no retained manual backup was found" "run make relayer-backup before lifecycle changes"
      fi
    else
      doctor_result SKIP VM.RUNTIME.READY "runtime readiness does not apply while the workload is absent" "run make relayer to install or reapply"
      doctor_result SKIP VM.KEYS.INTEGRITY "keystore integrity requires an installed restore utility" "reinstall from retained state, then rerun doctor"
      doctor_result SKIP VM.STATE.INTEGRITY "database integrity requires an installed restore utility" "reinstall from retained state, then rerun doctor"
      doctor_result SKIP VM.FUNDING.READY "funding readiness applies after installation" "install and fund the printed public addresses"
      doctor_result SKIP VM.LISTENERS.LOOPBACK "listener checks do not apply while the workload is absent" "none"
      doctor_result SKIP VM.RELEASE.INTEGRITY "installed release integrity does not apply while the workload is absent" "the installer will record immutable release metadata"
      doctor_result SKIP VM.BACKUPS.INTEGRITY "backup freshness applies after installation" "run make relayer-backup after installation"
    fi
  else
    doctor_result SKIP VM.TARGET.ARCHITECTURE "target architecture was not checked" "repair the remote preflight"
    doctor_result SKIP VM.TARGET.CAPACITY "target capacity was not checked" "repair the remote preflight"
    doctor_result SKIP VM.INSTALLATION.STATE "installation state was not classified" "repair the remote preflight"
    doctor_result SKIP VM.SAFE.CONSOLE_ENV "installed Safe console variables were not checked" "repair the remote preflight"
    doctor_result SKIP VM.CONFIG.BOOTSTRAP "installed bootstrap configuration was not checked" "repair the remote preflight"
    doctor_result SKIP VM.RELEASE.AVAILABLE "release availability was not architecture-matched" "repair the remote preflight"
    doctor_result SKIP VM.RUNTIME.READY "runtime readiness was not checked" "repair the remote preflight"
    doctor_result SKIP VM.KEYS.INTEGRITY "keystore integrity was not checked" "repair the remote preflight"
    doctor_result SKIP VM.STATE.INTEGRITY "state integrity was not checked" "repair the remote preflight"
    doctor_result SKIP VM.FUNDING.READY "funding was not checked" "repair the remote preflight"
    doctor_result SKIP VM.LISTENERS.LOOPBACK "listeners were not checked" "repair the remote preflight"
    doctor_result SKIP VM.RELEASE.INTEGRITY "installed release integrity was not checked" "repair the remote preflight"
    doctor_result SKIP VM.BACKUPS.INTEGRITY "backups were not checked" "repair the remote preflight"
  fi

  doctor_finish
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required; install it and rerun"
}

read_console_password() {
  local output_name="$1"
  local entered_password=""
  local confirmed_password=""

  while true; do
    printf 'Console password (press Enter for none): ' >&2
    if ! IFS= read -r -s entered_password; then
      printf '\n' >&2
      entered_password=""
      confirmed_password=""
      return 1
    fi
    printf '\n' >&2

    if [[ -z "$entered_password" ]]; then
      printf -v "$output_name" '%s' ""
      return 0
    fi

    printf 'Confirm console password: ' >&2
    if ! IFS= read -r -s confirmed_password; then
      printf '\n' >&2
      entered_password=""
      confirmed_password=""
      return 1
    fi
    printf '\n' >&2

    if [[ "$entered_password" == "$confirmed_password" ]]; then
      printf -v "$output_name" '%s' "$entered_password"
      entered_password=""
      confirmed_password=""
      return 0
    fi

    entered_password=""
    confirmed_password=""
    printf 'Console passwords did not match; try again.\n' >&2
  done
}

managed_info_rpc_url() {
  case "$1" in
    fuji) printf '%s\n' "https://api.avax-test.network" ;;
    mainnet) printf '%s\n' "https://api.avax.network" ;;
    *) return 1 ;;
  esac
}

validate_release_source() {
  [[ "$RELAYER_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || \
    die "invalid Relayer release repository: $RELAYER_REPOSITORY"
  if [[ "$RELAYER_REPOSITORY" != "ava-labs/validator-lifecycle-relayer" || -n "$RELAYER_DEVELOPMENT_TOKEN" ]]; then
    [[ "${RELAYER_DEVELOPMENT:-false}" == "true" ]] || \
      die "repository or authentication overrides require RELAYER_DEVELOPMENT=true and are not part of the supported operator flow"
  fi
}

release_curl() {
  if [[ -n "$RELAYER_DEVELOPMENT_TOKEN" ]]; then
    curl --config <(printf 'header = "Authorization: Bearer %s"\n' "$RELAYER_DEVELOPMENT_TOKEN") "$@"
  else
    curl "$@"
  fi
}

cleanup() {
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT INT TERM
umask 077

ensure_work_dir() {
  if [[ -z "$WORK_DIR" ]]; then
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/avalanche-relayer.XXXXXX")"
  fi
}

discover_infrastructure() {
  local cloud
  local terraform_dir
  local inventory
  local rpc_output
  local candidate
  local inventory_json
  local actual_rpc_hosts
  local expected_validator_hosts
  local actual_validator_hosts
  local validator_public_ips
  local validator_private_ips
  local first_rpc
  local candidate_count
  local -a candidates

  require_command terraform
  require_command ansible-inventory
  require_command jq
  require_command python3
  ensure_work_dir
  candidates=()

  for cloud in aws gcp azure; do
    terraform_dir="$ROOT_DIR/terraform/l1/$cloud"
    inventory="$ROOT_DIR/ansible/inventory/${cloud}_hosts"
    [[ -f "$inventory" ]] || continue
    if rpc_output="$(terraform -chdir="$terraform_dir" output -json rpc_ips 2>/dev/null)" && \
      jq -e 'type == "array" and length > 0' >/dev/null <<<"$rpc_output"; then
      candidates+=("$cloud")
    fi
  done

  candidate_count="${#candidates[@]}"
  if [[ "$candidate_count" -eq 0 ]]; then
    die "no Avalanche Deploy L1 Terraform state with a matching ansible/inventory/<cloud>_hosts file was found; apply exactly one of terraform/l1/{aws,gcp,azure} first"
  fi
  if [[ "$candidate_count" -ne 1 ]]; then
    candidate="$(IFS=,; printf '%s' "${candidates[*]}")"
    die "multiple deployed L1 states match Ansible inventories ($candidate); retain only the intended workspace state before installing"
  fi

  CLOUD="${candidates[0]}"
  INVENTORY_FILE="$ROOT_DIR/ansible/inventory/${CLOUD}_hosts"
  terraform_dir="$ROOT_DIR/terraform/l1/$CLOUD"
  inventory_json="$WORK_DIR/inventory.json"
  INVENTORY_SUMMARY="$WORK_DIR/inventory-summary.json"

  ANSIBLE_CONFIG="$ROOT_DIR/ansible/ansible.cfg" \
    ansible-inventory -i "$INVENTORY_FILE" --list >"$inventory_json"
  python3 - "$inventory_json" >"$INVENTORY_SUMMARY" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    inventory = json.load(f)

hostvars = inventory.get("_meta", {}).get("hostvars", {})

def group_hosts(name, seen=None):
    seen = set() if seen is None else seen
    if name in seen:
        return []
    seen.add(name)
    group = inventory.get(name, {})
    result = list(group.get("hosts", []))
    for child in group.get("children", []):
        result.extend(group_hosts(child, seen))
    return list(dict.fromkeys(result))

def describe(name):
    values = hostvars.get(name, {})
    return {
        "name": name,
        "ansibleHost": str(values.get("ansible_host", name)),
        "privateIp": str(values.get("private_ip", "")),
        "user": str(values.get("ansible_user", "")),
        "port": int(values.get("ansible_port", 22)),
        "privateKeyFile": str(values.get("ansible_ssh_private_key_file", "")),
    }

rpc = [describe(name) for name in group_hosts("rpc")]
validators = [describe(name) for name in group_hosts("validators")]
if not rpc:
    raise SystemExit("inventory group 'rpc' has no hosts")
if not validators:
    raise SystemExit("inventory group 'validators' has no hosts")
json.dump({"rpc": rpc, "validators": validators}, sys.stdout, indent=2)
PY

  rpc_output="$(terraform -chdir="$terraform_dir" output -json rpc_ips)"
  actual_rpc_hosts="$(jq -c '[.rpc[].ansibleHost]' "$INVENTORY_SUMMARY")"
  jq -n -e --argjson expected "$rpc_output" --argjson actual "$actual_rpc_hosts" \
    '($expected | sort) == ($actual | sort)' >/dev/null || \
    die "Terraform rpc_ips and $INVENTORY_FILE disagree; regenerate the Ansible inventory from the active state"

  validator_public_ips="$(terraform -chdir="$terraform_dir" output -json validator_ips)"
  validator_private_ips="$(terraform -chdir="$terraform_dir" output -json validator_private_ips)"
  expected_validator_hosts="$(jq -c '.' <<<"$validator_public_ips")"
  actual_validator_hosts="$(jq -c '[.validators[].ansibleHost]' "$INVENTORY_SUMMARY")"
  jq -n -e --argjson expected "$expected_validator_hosts" --argjson actual "$actual_validator_hosts" \
    '($expected | sort) == ($actual | sort)' >/dev/null || \
    die "Terraform validator_ips and $INVENTORY_FILE disagree; regenerate the Ansible inventory from the active state"

  VALIDATOR_PRIVATE_IPS="$(python3 - "$INVENTORY_SUMMARY" "$validator_public_ips" "$validator_private_ips" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    summary = json.load(f)
public = json.loads(sys.argv[2])
private = json.loads(sys.argv[3])
if len(public) != len(private):
    raise SystemExit("Terraform validator public/private IP outputs have different lengths")
result = {}
for host in summary["validators"]:
    try:
        index = public.index(host["ansibleHost"])
    except ValueError as exc:
        raise SystemExit(f"validator {host['name']} is not present in Terraform output") from exc
    result[host["name"]] = private[index] or host["privateIp"] or host["ansibleHost"]
json.dump(result, sys.stdout, separators=(",", ":"))
PY
)"

  TARGET_NAME="$(jq -r '.rpc[0].name' "$INVENTORY_SUMMARY")"
  TARGET_HOST="$(jq -r '.rpc[0].ansibleHost' "$INVENTORY_SUMMARY")"
  first_rpc="$(jq -r '.[0]' <<<"$rpc_output")"
  [[ "$first_rpc" == "$TARGET_HOST" ]] || \
    die "rpc[0] resolves to $TARGET_HOST in Ansible but $first_rpc in Terraform; regenerate the inventory so target selection is unambiguous"
}

load_l1_metadata() {
  require_command python3
  ensure_work_dir
  [[ -f "$L1_ENV" ]] || die "l1.env is missing; create and initialize the Avalanche Deploy L1 before installing the Relayer"
  METADATA_FILE="$WORK_DIR/l1-metadata.json"
  python3 - "$L1_ENV" >"$METADATA_FILE" <<'PY'
import json
import re
import shlex
import sys

values = {}
with open(sys.argv[1], encoding="utf-8") as f:
    for number, raw in enumerate(f, 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise SystemExit(f"l1.env:{number}: expected KEY=VALUE")
        key, value = line.split("=", 1)
        key = key.strip()
        if not re.fullmatch(r"[A-Z][A-Z0-9_]*", key):
            raise SystemExit(f"l1.env:{number}: invalid key {key!r}")
        value = value.strip()
        if value.startswith(("'", '"')):
            parsed = shlex.split(value, comments=False, posix=True)
            if len(parsed) != 1:
                raise SystemExit(f"l1.env:{number}: invalid quoted value")
            value = parsed[0]
        values[key] = value

required = {
    "network": "NETWORK",
    "subnetId": "SUBNET_ID",
    "blockchainId": "CHAIN_ID",
    "evmChainId": "EVM_CHAIN_ID",
    "chainName": "CHAIN_NAME",
    "managerAddress": "POA_MANAGER",
    "validatorManagerAddress": "VALIDATOR_MANAGER_PROXY",
}
missing = [env_key for env_key in required.values() if not values.get(env_key)]
if missing:
    raise SystemExit(
        "l1.env is missing " + ", ".join(missing) +
        "; rerun the Avalanche Deploy L1 creation/PoAManager initialization so generated metadata is persisted"
    )
network = values["NETWORK"].lower()
if network not in {"fuji", "mainnet"}:
    raise SystemExit(f"unsupported NETWORK={values['NETWORK']!r}; V1 supports only fuji and mainnet")
try:
    evm_chain_id = int(values["EVM_CHAIN_ID"], 10)
except ValueError as exc:
    raise SystemExit("EVM_CHAIN_ID must be a positive decimal integer") from exc
if evm_chain_id <= 0:
    raise SystemExit("EVM_CHAIN_ID must be a positive decimal integer")
for key in ("POA_MANAGER", "VALIDATOR_MANAGER_PROXY"):
    if not re.fullmatch(r"0x[0-9a-fA-F]{40}", values[key]):
        raise SystemExit(f"{key} must be a 20-byte EVM address")
if values["POA_MANAGER"].lower() == values["VALIDATOR_MANAGER_PROXY"].lower():
    raise SystemExit("POA_MANAGER and VALIDATOR_MANAGER_PROXY must be different official PoA topology contracts")

result = {name: values[env_key] for name, env_key in required.items()}
result["network"] = network
result["networkId"] = 5 if network == "fuji" else 1
result["evmChainId"] = evm_chain_id
json.dump(result, sys.stdout, indent=2)
PY
  INFO_RPC_URL="$(managed_info_rpc_url "$(jq -r '.network' "$METADATA_FILE")")" || \
    die "failed to select the managed Info API for $(jq -r '.network' "$METADATA_FILE")"
}

run_preflight() {
  local enforce_bootstrap="${1:-true}"
  local vars_file
  discover_infrastructure
  load_l1_metadata
  DISCOVERY_FILE="$WORK_DIR/discovery.json"
  vars_file="$WORK_DIR/discovery-vars.json"
  jq -n \
    --arg target "$TARGET_NAME" \
    --arg output "$DISCOVERY_FILE" \
    --arg subnet "$(jq -r '.subnetId' "$METADATA_FILE")" \
    --arg blockchain "$(jq -r '.blockchainId' "$METADATA_FILE")" \
    --arg chain_name "$(jq -r '.chainName' "$METADATA_FILE")" \
    --arg manager "$(jq -r '.managerAddress' "$METADATA_FILE")" \
    --arg validator_manager "$(jq -r '.validatorManagerAddress' "$METADATA_FILE")" \
    --arg info_rpc_url "$INFO_RPC_URL" \
    --argjson network_id "$(jq '.networkId' "$METADATA_FILE")" \
    --argjson evm_chain_id "$(jq '.evmChainId' "$METADATA_FILE")" \
    --argjson validator_private_ips "$VALIDATOR_PRIVATE_IPS" \
    '{
      acp_relayer_discovered_target: $target,
      acp_relayer_discovery_file: $output,
      acp_relayer_expected_subnet_id: $subnet,
      acp_relayer_expected_blockchain_id: $blockchain,
      acp_relayer_expected_chain_name: $chain_name,
      acp_relayer_expected_manager_address: $manager,
      acp_relayer_expected_validator_manager_address: $validator_manager,
      acp_relayer_info_rpc_url: $info_rpc_url,
      acp_relayer_expected_network_id: $network_id,
      acp_relayer_expected_evm_chain_id: $evm_chain_id,
      acp_relayer_validator_private_ips: $validator_private_ips
    }' >"$vars_file"

  (
    cd "$ROOT_DIR/ansible"
    ANSIBLE_CONFIG="$ROOT_DIR/ansible/ansible.cfg" \
      ansible-playbook -i "$INVENTORY_FILE" playbooks/l1/discover-relayer.yml -e "@$vars_file"
  )
  jq -e --arg target "$TARGET_NAME" --arg info_rpc_url "$INFO_RPC_URL" \
    '.target == $target and .infoRpcUrl == $info_rpc_url and
     (.eligibleBootstrapPeerCount | type) == "number" and
     (.peers | length > 0) and (.architecture | length > 0)' \
    "$DISCOVERY_FILE" >/dev/null || \
    die "Relayer discovery did not produce a complete result; inspect the Ansible preflight output above"
  if [[ "$enforce_bootstrap" == true ]]; then
    jq -e '.eligibleBootstrapPeerCount > 0' "$DISCOVERY_FILE" >/dev/null || \
      die "the managed Info API has no peers in the current Primary validator set; rerun make relayer-doctor for remediation"
  fi
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    die "shasum or sha256sum is required to verify Relayer release artifacts"
  fi
}

download_release_asset() {
  local asset="$1"
  local destination="$2"
  release_curl -fL --retry 3 --retry-delay 1 \
    "https://github.com/$RELAYER_REPOSITORY/releases/download/$RELAYER_VERSION/$asset" \
    -o "$destination"
}

verify_release_asset() {
  local archive="$1"
  local checksums="$2"
  local asset
  local expected
  local actual
  asset="$(basename "$archive")"
  expected="$(awk -v name="$asset" '{file=$2; sub(/^\\*/, "", file); if (file == name) print $1}' "$checksums")"
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || die "checksums.txt has no SHA256 entry for $asset"
  actual="$(sha256_file "$archive")"
  actual="$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')"
  expected="$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')"
  [[ "$actual" == "$expected" ]] || die "SHA256 mismatch for published Relayer asset $asset"
}

prepare_release() {
  local need_setup="$1"
  local release_dir
  local checksums
  local version_without_v
  local remote_architecture
  local remote_arch
  local local_os
  local local_architecture
  local local_arch
  local daemon_asset
  local daemon_archive
  local daemon_bundle
  local setup_asset
  local setup_archive
  local setup_bundle
  local image_file

  require_command curl
  require_command tar
  ensure_work_dir
  release_dir="$WORK_DIR/release"
  mkdir -p "$release_dir"
  checksums="$release_dir/checksums.txt"
  version_without_v="${RELAYER_VERSION#v}"
  download_release_asset checksums.txt "$checksums"

  remote_architecture="$(jq -r '.architecture' "$DISCOVERY_FILE")"
  case "$remote_architecture" in
    x86_64 | amd64) remote_arch=amd64 ;;
    aarch64 | arm64) remote_arch=arm64 ;;
    *) die "unsupported rpc[0] architecture from Ansible: $remote_architecture" ;;
  esac
  daemon_asset="relayer_${version_without_v}_linux_${remote_arch}.tar.gz"
  daemon_archive="$release_dir/$daemon_asset"
  download_release_asset "$daemon_asset" "$daemon_archive"
  verify_release_asset "$daemon_archive" "$checksums"
  tar -xzf "$daemon_archive" -C "$release_dir"
  daemon_bundle="$release_dir/${daemon_asset%.tar.gz}"
  RELEASE_BINARY="$daemon_bundle/relayerd"
  [[ -x "$RELEASE_BINARY" ]] || die "$daemon_asset does not contain an executable relayerd"
  RELEASE_RESTORE="$daemon_bundle/relayer-restore"
  [[ -x "$RELEASE_RESTORE" ]] || die "$daemon_asset does not contain an executable relayer-restore"

  image_file="$release_dir/relayer-console-image.txt"
  download_release_asset relayer-console-image.txt "$image_file"
  verify_release_asset "$image_file" "$checksums"
  CONSOLE_IMAGE="$(tr -d '[:space:]' <"$image_file")"
  [[ "$CONSOLE_IMAGE" =~ ^ghcr\.io/.+@sha256:[0-9a-f]{64}$ ]] || \
    die "published relayer-console-image.txt does not contain an immutable OCI digest"

  if [[ "$need_setup" != "true" ]]; then
    return
  fi
  case "$(uname -s)" in
    Darwin) local_os=darwin ;;
    Linux) local_os=linux ;;
    *) die "relayer-setup supports only macOS and Linux control hosts" ;;
  esac
  local_architecture="$(uname -m)"
  case "$local_architecture" in
    x86_64 | amd64) local_arch=amd64 ;;
    aarch64 | arm64) local_arch=arm64 ;;
    *) die "unsupported control-host architecture: $local_architecture" ;;
  esac
  setup_asset="relayer_${version_without_v}_${local_os}_${local_arch}.tar.gz"
  setup_archive="$release_dir/$setup_asset"
  if [[ "$setup_archive" != "$daemon_archive" ]]; then
    download_release_asset "$setup_asset" "$setup_archive"
    verify_release_asset "$setup_archive" "$checksums"
    tar -xzf "$setup_archive" -C "$release_dir"
  fi
  setup_bundle="$release_dir/${setup_asset%.tar.gz}"
  RELEASE_SETUP="$setup_bundle/relayer-setup"
  [[ -x "$RELEASE_SETUP" ]] || die "$setup_asset does not contain an executable relayer-setup"
}

run_manage_playbook() {
  local action="$1"
  local purge="${2:-false}"
  local vars_file
  ensure_work_dir
  vars_file="$WORK_DIR/manage-vars.json"
  local backup_dir=""
  if [[ "$action" == backup ]]; then
    backup_dir="${RELAYER_BACKUP_DIR:-$ROOT_DIR/backups/relayer}"
    mkdir -p "$backup_dir"
    chmod 0700 "$backup_dir"
  fi
  jq -n --arg action "$action" --argjson purge "$purge" --arg backup_dir "$backup_dir" \
    '{relayer_manage_action: $action, relayer_purge: $purge, relayer_backup_fetch_dir: $backup_dir}' >"$vars_file"
  (
    cd "$ROOT_DIR/ansible"
    ANSIBLE_CONFIG="$ROOT_DIR/ansible/ansible.cfg" \
      ansible-playbook -i "$INVENTORY_FILE" playbooks/l1/manage-relayer.yml -e "@$vars_file"
  )
  if [[ "$action" == backup ]]; then
    find "$backup_dir" -type f \( -name '*.tar.gz' -o -name '*.manifest.json' \) -exec chmod 0600 {} +
  fi
}

run_install() {
  local answer
  local target_label
  local console_password
  local bundle_dir
  local setup_result
  local setup_config
  local rewritten_config
  local funding_file
  local console_hash_src
  local preserve_keystore
  local safe_enabled
  local safe_address
  local vars_file
  local peer
  local -a setup_args

  if ! doctor_vm install; then
    die "Relayer doctor found blockers; apply the printed remediations before installation"
  fi
  run_preflight
  target_label="$TARGET_NAME ($TARGET_HOST)"
  printf 'Install the relayer and console on %s? [y/N] ' "$target_label"
  IFS= read -r answer
  case "$answer" in
    y | Y | yes | YES | Yes) ;;
    *) printf 'Installation cancelled.\n'; return 0 ;;
  esac
  if ! read_console_password console_password; then
    die "console password entry was interrupted; installation was not started"
  fi

  prepare_release true
  bundle_dir="$WORK_DIR/generated"
  setup_result="$WORK_DIR/setup-result.json"
  setup_args=(
    --out "$bundle_dir"
    --l1-env "$L1_ENV"
    --pchain-rpc-url http://127.0.0.1:9650
    --info-rpc-url "$INFO_RPC_URL"
    --evm-rpc-url "http://127.0.0.1:9650/ext/bc/$(jq -r '.blockchainId' "$METADATA_FILE")/rpc"
    --api-listen-addr 127.0.0.1:8081
    --output json
  )
  while IFS= read -r peer; do
    setup_args+=(--peer "$peer")
  done < <(jq -r '.peers[] | .["node-id"] + "@" + .ip' "$DISCOVERY_FILE")
  RELAYER_CONSOLE_PASSWORD="$console_password" "$RELEASE_SETUP" "${setup_args[@]}" >"$setup_result"
  console_password=""

  setup_config="$(jq -r '.configFile' "$setup_result")"
  rewritten_config="$WORK_DIR/config.json"
  jq \
    --arg keystore /var/lib/relayerd/keystore.json \
    --arg tls_cert /var/lib/relayerd/tls/staker.crt \
    --arg tls_key /var/lib/relayerd/tls/staker.key \
    --arg database /var/lib/relayerd/relayer.db \
    --arg backups /var/backups/relayerd \
    '."tls-cert-path" = $tls_cert |
     ."tls-key-path" = $tls_key |
     ."bbolt-path" = $database |
     ."api-listen-addr" = "127.0.0.1:8081" |
     ."key-source"."backend" = "encrypted-file" |
     ."key-source"."encrypted-file" = $keystore |
     ."state-backup" = {"dir": $backups, "interval-seconds": 300}' \
    "$setup_config" >"$rewritten_config"

  funding_file="$WORK_DIR/funding.json"
  jq --arg manager "$(jq -r '.managerAddress' "$METADATA_FILE")" \
    --arg validator_manager "$(jq -r '.validatorManagerAddress' "$METADATA_FILE")" \
    '{version, pChainAddress, evmAddress, networkId, subnetId, blockchainId, evmChainId, chainName,
      managerAddress: $manager, validatorManagerAddress: $validator_manager}' \
    "$setup_result" >"$funding_file"
  console_hash_src="$(jq -r '.consolePasswordHashFile // ""' "$setup_result")"
  preserve_keystore="$(jq '.keystoreExists' "$DISCOVERY_FILE")"
  safe_enabled="$(jq '.safeServicesDetected' "$DISCOVERY_FILE")"
  safe_address="$(jq -r '.managerOwner' "$DISCOVERY_FILE")"
  vars_file="$WORK_DIR/deploy-vars.json"
  jq -n \
    --arg target "$TARGET_NAME" \
    --arg version "$RELAYER_VERSION" \
    --arg binary "$RELEASE_BINARY" \
    --arg restore_binary "$RELEASE_RESTORE" \
    --arg image "$CONSOLE_IMAGE" \
    --arg blockchain "$(jq -r '.blockchainId' "$METADATA_FILE")" \
    --arg config "$rewritten_config" \
    --arg keystore "$(jq -r '.keystoreFile' "$setup_result")" \
    --arg password "$(jq -r '.keystorePasswordFile' "$setup_result")" \
    --arg session "$(jq -r '.consoleSessionSecretFile' "$setup_result")" \
    --arg console_hash "$console_hash_src" \
    --arg funding "$funding_file" \
    --arg safe_address "$safe_address" \
    --argjson preserve "$preserve_keystore" \
    --argjson safe_enabled "$safe_enabled" \
    '{
      acp_relayer_discovered_target: $target,
      acp_relayer_operation: "install",
      acp_relayer_version: $version,
      acp_relayer_binary_local_src: $binary,
      acp_relayer_restore_binary_local_src: $restore_binary,
      acp_relayer_console_image: $image,
      acp_relayer_blockchain_id: $blockchain,
      acp_relayer_config_src: $config,
      acp_relayer_keystore_src: $keystore,
      acp_relayer_keystore_password_src: $password,
      acp_relayer_console_session_secret_src: $session,
      acp_relayer_console_password_hash_src: $console_hash,
      acp_relayer_funding_src: $funding,
      acp_relayer_preserve_keystore: $preserve,
      acp_relayer_safe_enabled: $safe_enabled,
      acp_relayer_safe_address: $safe_address
    }' >"$vars_file"

  (
    cd "$ROOT_DIR/ansible"
    ANSIBLE_CONFIG="$ROOT_DIR/ansible/ansible.cfg" \
      ansible-playbook -i "$INVENTORY_FILE" playbooks/l1/deploy-relayer.yml -e "@$vars_file"
  )
}

run_upgrade() {
  local vars_file
  [[ "$RELAYER_VERSION" != "$PINNED_RELAYER_VERSION" ]] || \
    die "RELAYER_VERSION is required for upgrades; run make relayer-upgrade RELAYER_VERSION=vX.Y.Z"
  run_preflight
  run_manage_playbook backup
  prepare_release false
  vars_file="$WORK_DIR/upgrade-vars.json"
  jq -n \
    --arg target "$TARGET_NAME" \
    --arg version "$RELAYER_VERSION" \
    --arg binary "$RELEASE_BINARY" \
    --arg restore_binary "$RELEASE_RESTORE" \
    --arg image "$CONSOLE_IMAGE" \
    --arg blockchain "$(jq -r '.blockchainId' "$METADATA_FILE")" \
    '{
      acp_relayer_discovered_target: $target,
      acp_relayer_operation: "upgrade",
      acp_relayer_version: $version,
      acp_relayer_binary_local_src: $binary,
      acp_relayer_restore_binary_local_src: $restore_binary,
      acp_relayer_console_image: $image,
      acp_relayer_blockchain_id: $blockchain
    }' >"$vars_file"
  (
    cd "$ROOT_DIR/ansible"
    ANSIBLE_CONFIG="$ROOT_DIR/ansible/ansible.cfg" \
      ansible-playbook -i "$INVENTORY_FILE" playbooks/l1/deploy-relayer.yml -e "@$vars_file"
  )
}

run_restore() {
  local backup="${BACKUP:-}" manifest expected actual answer vars_file
  [[ -n "$backup" ]] || die "BACKUP is required; use make relayer-restore BACKUP=/absolute/path/to/relayer-*.tar.gz"
  [[ "$backup" == /* ]] || die "BACKUP must be an absolute path to an archive created by make relayer-backup"
  [[ -f "$backup" ]] || die "BACKUP does not exist: $backup"
  [[ "$(basename "$backup")" =~ ^relayer-[0-9]{8}T[0-9]{6}\.tar\.gz$ ]] || \
    die "BACKUP filename is not a retained make relayer-backup archive"
  manifest="${backup%.tar.gz}.manifest.json"
  [[ -f "$manifest" ]] || die "matching backup manifest is missing: $manifest"

  require_command jq
  require_command python3
  expected="$(jq -r '.archive.sha256 // empty' "$manifest")"
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || die "backup manifest has no valid archive SHA-256"
  actual="$(sha256_file "$backup")"
  actual="$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')"
  expected="$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')"
  [[ "$actual" == "$expected" ]] || die "backup archive checksum does not match its manifest"
  jq -e --arg file "$(basename "$backup")" \
    '.schemaVersion == 1 and .kind == "avalanche-deploy-relayer-backup" and .archive.file == $file' \
    "$manifest" >/dev/null || die "backup manifest schema or archive name is invalid"
  python3 - "$backup" <<'PY'
import pathlib
import sys
import tarfile

with tarfile.open(sys.argv[1], "r:gz") as archive:
    members = archive.getmembers()
for member in members:
    name = member.name
    path = pathlib.PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts:
        raise SystemExit(f"unsafe archive member: {name}")
    if not (member.isfile() or member.isdir()):
        raise SystemExit(f"unsupported link or special archive member: {name}")
required = {
    "etc/relayerd/config.json",
    "etc/relayerd/funding.json",
    "etc/relayerd/secrets/keystore-password",
    "etc/relayerd/secrets/console-session-secret",
    "etc/relayerd/secrets/console.env",
    "var/lib/relayerd/keystore.json",
    "var/lib/relayerd/relayer.db",
    "var/lib/relayerd/tls/staker.crt",
    "var/lib/relayerd/tls/staker.key",
}
normalized = {member.name.removeprefix("./") for member in members}
missing = sorted(required - normalized)
if missing:
    raise SystemExit("backup is missing required members: " + ", ".join(missing))
PY

  run_preflight
  jq -e \
    --argjson network "$(jq '.networkId' "$METADATA_FILE")" \
    --arg subnet "$(jq -r '.subnetId' "$METADATA_FILE")" \
    --arg blockchain "$(jq -r '.blockchainId' "$METADATA_FILE")" \
    --argjson evm "$(jq '.evmChainId' "$METADATA_FILE")" \
    --arg chain_name "$(jq -r '.chainName' "$METADATA_FILE")" \
    --arg manager "$(jq -r '.managerAddress' "$METADATA_FILE")" \
    --arg validator_manager "$(jq -r '.validatorManagerAddress' "$METADATA_FILE")" \
    '.networkId == $network and .subnetId == $subnet and .blockchainId == $blockchain and
     .evmChainId == $evm and .chainName == $chain_name and
     (.managerAddress | ascii_downcase) == ($manager | ascii_downcase) and
     (.validatorManagerAddress | ascii_downcase) == ($validator_manager | ascii_downcase)' \
    "$manifest" >/dev/null || die "backup manifest belongs to a different Avalanche Deploy L1"

  printf 'Restore %s to %s (%s) and retain an automatic pre-restore rollback? [y/N] ' \
    "$(basename "$backup")" "$TARGET_NAME" "$TARGET_HOST"
  IFS= read -r answer
  case "$answer" in y|Y|yes|YES|Yes) ;; *) printf 'Restore cancelled; no changes made.\n'; return 0 ;; esac

  prepare_release false
  vars_file="$WORK_DIR/restore-vars.json"
  jq -n --arg archive "$backup" --arg utility "$RELEASE_RESTORE" \
    '{relayer_restore_archive_local: $archive, relayer_restore_utility_local: $utility}' >"$vars_file"
  (
    cd "$ROOT_DIR/ansible"
    ANSIBLE_CONFIG="$ROOT_DIR/ansible/ansible.cfg" \
      ansible-playbook -i "$INVENTORY_FILE" playbooks/l1/restore-relayer.yml -e "@$vars_file"
  )
  doctor_vm
}

ssh_target() {
  local user
  local port
  local key_file
  local destination
  local -a args
  user="$(jq -r '.rpc[0].user' "$INVENTORY_SUMMARY")"
  port="$(jq -r '.rpc[0].port' "$INVENTORY_SUMMARY")"
  key_file="$(jq -r '.rpc[0].privateKeyFile' "$INVENTORY_SUMMARY")"
  destination="$TARGET_HOST"
  [[ -n "$user" ]] && destination="$user@$destination"
  args=(-o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=20 -p "$port")
  if [[ -n "$key_file" ]]; then
    key_file="${key_file/#\~/$HOME}"
    args+=(-i "$key_file")
  fi

  case "$ACTION" in
    access)
      printf 'Console: http://127.0.0.1:3080\n'
      printf 'L1 RPC: http://127.0.0.1:9650/ext/bc/%s/rpc\n' "$(jq -r '.blockchainId' "$METADATA_FILE")"
      printf 'Safe UI (when installed): https://127.0.0.1:3081 (self-signed certificate; accept the browser warning)\n'
      exec ssh "${args[@]}" -N \
        -L 3080:127.0.0.1:3080 \
        -L 9650:127.0.0.1:9650 \
        -L 3081:127.0.0.1:443 \
        "$destination"
      ;;
    logs)
      exec ssh "${args[@]}" -t "$destination" \
        'sudo journalctl -u relayerd -u relayer-console -f --no-hostname'
      ;;
  esac
}

main() {
[[ $# -le 1 ]] || usage
validate_release_source
if [[ ! "$RELAYER_VERSION" =~ ^v[0-9A-Za-z][0-9A-Za-z.+-]*$ ]]; then
  printf 'ERROR: RELAYER_VERSION must be a release tag such as v0.1.0\n' >&2
  usage
fi
if [[ "$RELAYER_VERSION" == "$PINNED_RELAYER_VERSION" && "$ACTION" =~ ^(doctor|install)$ ]]; then
  die "the production Relayer pin is awaiting repository transfer; for an approved prerelease set RELAYER_DEVELOPMENT=true, RELAYER_DEVELOPMENT_REPOSITORY=owner/repository, and RELAYER_VERSION=vX.Y.Z-rc.N"
fi
case "$ACTION" in
  prereqs)
    exec "$ROOT_DIR/scripts/shared/relayer-prereqs.sh" vm
    ;;
  doctor)
    doctor_vm
    ;;
  install)
    run_install
    ;;
  access)
    discover_infrastructure
    load_l1_metadata
    ssh_target
    ;;
  logs)
    discover_infrastructure
    ssh_target
    ;;
  status)
    discover_infrastructure
    run_manage_playbook status
    ;;
  backup)
    discover_infrastructure
    load_l1_metadata
    run_manage_playbook backup
    ;;
  restore)
    run_restore
    ;;
  upgrade)
    run_upgrade
    ;;
  remove)
    discover_infrastructure
    if [[ "${PURGE:-false}" == "true" ]]; then
      printf 'Permanently delete relayer keys, state, TLS identity, and backups on %s (%s)? [y/N] ' "$TARGET_NAME" "$TARGET_HOST"
      IFS= read -r purge_answer
      case "$purge_answer" in
        y | Y | yes | YES | Yes) run_manage_playbook remove true ;;
        *) printf 'Purge cancelled; no changes made.\n' ;;
      esac
    else
      run_manage_playbook remove false
    fi
    ;;
  *)
    usage
    ;;
esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
