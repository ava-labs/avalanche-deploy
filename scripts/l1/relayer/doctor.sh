# shellcheck shell=bash
# Read-only local and remote health, safety, and readiness checks.

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
    if modified="$(stat -c %Y "$L1_ENV" 2>/dev/null || stat -f %m "$L1_ENV" 2>/dev/null)" && \
      [[ "$modified" =~ ^[0-9]+$ ]]; then
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
      ensure_work_dir
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
        if sed '1s/^[^{]*//' "$funding_status_file" | \
          jq -e '(.json // (.content | fromjson)) | .fundedFloat == true and .fundedGas == true' >/dev/null 2>&1; then
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
      if "${ansible_prefix[@]}" -m ansible.builtin.shell -a "ss -ltnH >/dev/null 2>&1 || exit 42; ss -ltnH | awk '\$4 ~ /:(8081|3080)$/ {print \$4}' | grep -Ev '^(127\\.0\\.0\\.1|\\[::1\\]):' || true; printf 'RELAYER_LISTENERS_SCANNED\\n'" >"$listeners_file" 2>/dev/null && \
        grep -Fqx 'RELAYER_LISTENERS_SCANNED' "$listeners_file"; then
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
