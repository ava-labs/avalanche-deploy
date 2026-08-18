# shellcheck shell=bash
# Interactive install and upgrade workflows.

read_console_password() {
  local output_name="$1"
  local reset_on_empty="${2:-true}"
  local entered_password=""
  local confirmed_password=""

  while true; do
    if [[ "$reset_on_empty" == true ]]; then
      printf 'Console password (press Enter for none): ' >&2
    else
      printf 'Console password (press Enter to keep the current console password): ' >&2
    fi
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

stage_relayer_identity() {
  local p2p_node_id="$1"
  local tls_certificate_sha256="$2"
  local tls_cert_src="$3"
  local tls_key_src="$4"
  local identity_src="$5"
  local vars_file="$WORK_DIR/identity-vars.json"

  jq -n \
    --arg target "$TARGET_NAME" \
    --arg cert "$tls_cert_src" \
    --arg key "$tls_key_src" \
    --arg identity "$identity_src" \
    --arg node_id "$p2p_node_id" \
    --arg certificate_sha256 "$tls_certificate_sha256" \
    '{
      acp_relayer_discovered_target: $target,
      acp_relayer_tls_cert_src: $cert,
      acp_relayer_tls_key_src: $key,
      acp_relayer_identity_src: $identity,
      acp_relayer_expected_p2p_node_id: $node_id,
      acp_relayer_expected_tls_certificate_sha256: $certificate_sha256
    }' >"$vars_file"

  (
    cd "$ROOT_DIR/ansible" || exit 1
    ANSIBLE_CONFIG="$ROOT_DIR/ansible/ansible.cfg" \
      ansible-playbook -i "$INVENTORY_FILE" playbooks/l1/stage-relayer-identity.yml -e "@$vars_file"
  )
}

generate_relayer_setup_bundle() {
  local console_password="$1"
  local bundle_dir="$2"
  local setup_result="$3"
  local peer
  local -a setup_args
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
  jq -e '
    (.p2pNodeId | startswith("NodeID-")) and
    (.tlsCertificateSha256 | test("^[0-9a-f]{64}$")) and
    (.tlsCertFile | type) == "string" and
    (.tlsKeyFile | type) == "string"
  ' "$setup_result" >/dev/null || die "relayer-setup did not return a complete permanent P2P identity"
}

write_identity_metadata() {
  local p2p_node_id="$1"
  local tls_certificate_sha256="$2"
  local identity_file="$3"
  jq -n \
    --arg node_id "$p2p_node_id" \
    --arg certificate_sha256 "$tls_certificate_sha256" \
    --arg version "$RELAYER_VERSION" \
    '{
      schemaVersion: 1,
      p2pNodeId: $node_id,
      tlsCertificateSha256: $certificate_sha256,
      createdByVersion: $version
    }' >"$identity_file"
}

derive_scanner_start_block() {
  local manager_metadata="$ROOT_DIR/validator-manager.json"
  local anchors vars_file result_file result
  if [[ ! -f "$manager_metadata" ]]; then
    printf 'Scanner start: validator-manager.json is unavailable; using genesis for complete coverage.\n' >&2
    printf '0\n'
    return 0
  fi
  if ! jq -e \
    --arg manager "$(jq -r '.managerAddress' "$METADATA_FILE")" \
    --arg proxy "$(jq -r '.validatorManagerAddress' "$METADATA_FILE")" '
      ((.poa_manager // "") | ascii_downcase) == ($manager | ascii_downcase) and
      ((.proxy // "") | ascii_downcase) == ($proxy | ascii_downcase)
    ' "$manager_metadata" >/dev/null; then
    printf 'Scanner start: validator-manager.json does not match l1.env; using genesis.\n' >&2
    printf '0\n'
    return 0
  fi
  anchors="$(jq -c '
    [
      {txHash: .init_settings_tx, selector: "0x736c87be"},
      {txHash: .init_validators_tx, selector: "0x20d91b7a"}
    ]
    | map(select(.txHash | type == "string" and test("^0x[0-9a-fA-F]{64}$")))
    | unique_by(.txHash, .selector)
  ' "$manager_metadata")"
  if [[ "$(jq 'length' <<<"$anchors")" -eq 0 ]]; then
    printf 'Scanner start: manager initialization transactions are unavailable; using genesis.\n' >&2
    printf '0\n'
    return 0
  fi

  vars_file="$WORK_DIR/scanner-start-vars.json"
  result_file="$WORK_DIR/scanner-start-result.json"
  jq -n \
    --arg blockchain "$(jq -r '.blockchainId' "$METADATA_FILE")" \
    --arg manager "$(jq -r '.managerAddress' "$METADATA_FILE")" \
    --arg proxy "$(jq -r '.validatorManagerAddress' "$METADATA_FILE")" \
    --arg output "$result_file" \
    --argjson anchors "$anchors" \
    '{
      relayer_scanner_blockchain_id: $blockchain,
      relayer_scanner_anchors: $anchors,
      relayer_scanner_manager_addresses: [$proxy],
      relayer_scanner_result_local: $output
    }' >"$vars_file"
  (
    cd "$ROOT_DIR/ansible" || exit 1
    ANSIBLE_CONFIG="$ROOT_DIR/ansible/ansible.cfg" \
      ansible-playbook -i "$INVENTORY_FILE" playbooks/l1/derive-relayer-scanner-start.yml -e "@$vars_file"
  ) >/dev/null
  result="$(jq -r '.startBlock' "$result_file")"
  if [[ "$(jq -r '.derived' "$result_file")" == true ]]; then
    printf 'Scanner start: verified finalized manager initialization block %s.\n' "$result" >&2
  else
    printf 'Scanner start: %s; using genesis for complete coverage.\n' \
      "$(jq -r '.reason // "anchor derivation failed"' "$result_file")" >&2
  fi
  printf '%s\n' "$result"
}

resolve_install_scanner_settings() {
  local operation="$1"
  local discovery_file="$2"
  EFFECTIVE_RELAYER_SCANNER_POLL_SECONDS="$RELAYER_SCANNER_POLL_SECONDS"
  EFFECTIVE_RELAYER_SCANNER_START_BLOCK="$RELAYER_SCANNER_START_BLOCK"
  if [[ "$operation" != install && "$RESOLVED_RELAYER_SCANNER_ENABLED" == true ]]; then
    if [[ -z "$RELAYER_SCANNER_POLL_SECONDS_EXPLICIT" ]]; then
      EFFECTIVE_RELAYER_SCANNER_POLL_SECONDS="$(
        jq -r --argjson fallback "$RELAYER_SCANNER_POLL_SECONDS" \
          '.existingScanner["poll-interval-seconds"] // $fallback' "$discovery_file"
      )"
    fi
    if [[ -z "$RELAYER_SCANNER_START_BLOCK_EXPLICIT" ]]; then
      if jq -e '.existingScanner["start-block"] | type == "number"' "$discovery_file" >/dev/null; then
        EFFECTIVE_RELAYER_SCANNER_START_BLOCK="$(jq -r '.existingScanner["start-block"]' "$discovery_file")"
      else
        EFFECTIVE_RELAYER_SCANNER_START_BLOCK="$(derive_scanner_start_block)"
      fi
    fi
  elif [[ "$operation" == install && "$RESOLVED_RELAYER_SCANNER_ENABLED" == true && -z "$RELAYER_SCANNER_START_BLOCK_EXPLICIT" ]]; then
    EFFECTIVE_RELAYER_SCANNER_START_BLOCK="$(derive_scanner_start_block)"
  fi
}

run_prepare() {
  local validator_count private_count tls_identity_exists tls_pair_exists
  local p2p_node_id tls_certificate_sha256 answer bundle_dir setup_result identity_file
  run_authorization_preflight
  read -r validator_count private_count < <(protocol_privacy_counts "$DISCOVERY_FILE")
  ((private_count == 0 || private_count == validator_count)) || \
    die "validatorOnly is inconsistent across the L1 validator set; identity preparation made no changes"

  tls_identity_exists="$(jq -r '.tlsIdentityExists' "$DISCOVERY_FILE")"
  tls_pair_exists="$(jq -r '.tlsPairExists' "$DISCOVERY_FILE")"
  if [[ "$tls_identity_exists" == true ]]; then
    p2p_node_id="$(jq -r '.p2pNodeId' "$DISCOVERY_FILE")"
    printf 'Reusing permanent Relayer P2P NodeID: %s\n' "$p2p_node_id"
  else
    if [[ "$tls_pair_exists" == true ]] || \
      [[ "$(jq -r '.daemonInstalled or .consoleInstalled or .keystoreExists' "$DISCOVERY_FILE")" == true ]]; then
      die "Relayer state is partial and has no complete permanent identity; restore matching state or explicitly purge it before preparation"
    fi
    printf 'Create and stage a permanent Relayer identity on %s (%s)? [y/N] ' "$TARGET_NAME" "$TARGET_HOST"
    IFS= read -r answer
    case "$answer" in
      y | Y | yes | YES | Yes) ;;
      *) printf 'Identity preparation cancelled; no changes were made.\n'; return 0 ;;
    esac

    prepare_release true
    bundle_dir="$WORK_DIR/prepared-bundle"
    setup_result="$WORK_DIR/prepared-setup-result.json"
    generate_relayer_setup_bundle "" "$bundle_dir" "$setup_result"
    p2p_node_id="$(jq -r '.p2pNodeId' "$setup_result")"
    tls_certificate_sha256="$(jq -r '.tlsCertificateSha256' "$setup_result")"
    identity_file="$WORK_DIR/identity.json"
    write_identity_metadata "$p2p_node_id" "$tls_certificate_sha256" "$identity_file"
    stage_relayer_identity \
      "$p2p_node_id" \
      "$tls_certificate_sha256" \
      "$(jq -r '.tlsCertFile' "$setup_result")" \
      "$(jq -r '.tlsKeyFile' "$setup_result")" \
      "$identity_file"
    run_authorization_preflight
    [[ "$(jq -r '.tlsIdentityExists' "$DISCOVERY_FILE")" == true ]] || \
      die "the permanent identity was not visible after staging"
    [[ "$(jq -r '.p2pNodeId' "$DISCOVERY_FILE")" == "$p2p_node_id" ]] || \
      die "the staged identity returned a different NodeID"
    printf 'Permanent Relayer identity prepared: %s\n' "$p2p_node_id"
  fi

  if ((private_count == 0)); then
    printf 'Protocol privacy is disabled. Run make relayer to install and start the Relayer.\n'
  else
    print_protocol_authorization "$p2p_node_id" "$DISCOVERY_FILE"
    if authorization_needed "$p2p_node_id" "$DISCOVERY_FILE"; then
      printf 'For Terraform/Ansible-managed nodes, run make relayer-authorize.\n'
      printf 'For manual or external nodes, follow %s\n' "$RELAYER_MANUAL_AUTHORIZATION_URL"
      printf 'Run make relayer after authorization.\n'
    else
      printf 'Authorization is already complete. Run make relayer.\n'
    fi
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
  local console_installed
  local console_password_reset
  local preserve_keystore
  local tls_identity_exists
  local tls_pair_exists
  local p2p_node_id
  local tls_certificate_sha256
  local identity_file
  local safe_enabled
  local safe_address
  local vars_file
  local role_operation
  local current_state_schema
  local effective_scanner_poll effective_scanner_start
  local validator_count private_count

  run_authorization_preflight
  read -r validator_count private_count < <(protocol_privacy_counts "$DISCOVERY_FILE")
  if ((private_count > 0)); then
    ((private_count == validator_count)) || \
      die "validatorOnly is inconsistent across the L1 validator set"
    if [[ "$(jq -r '.tlsIdentityExists' "$DISCOVERY_FILE")" != true ]]; then
      printf 'ERROR: prepare the permanent Relayer identity before installing on a protocol-private L1.\n' >&2
      printf 'Run: make relayer-prepare RELAYER_VERSION=%s\n' "$RELAYER_VERSION" >&2
      return 1
    fi
    p2p_node_id="$(jq -r '.p2pNodeId' "$DISCOVERY_FILE")"
    if authorization_needed "$p2p_node_id" "$DISCOVERY_FILE"; then
      offer_managed_authorization "$p2p_node_id" || return 1
    fi
  fi
  if ! doctor_vm install; then
    die "Relayer doctor found blockers; apply the printed remediations before installation"
  fi
  run_preflight
  if ((private_count > 0)); then
    p2p_node_id="$(jq -r '.p2pNodeId' "$DISCOVERY_FILE")"
    protocol_privacy_gate "$p2p_node_id" "$DISCOVERY_FILE" || return 1
    peer_visibility_gate "$DISCOVERY_FILE" || return 1
  fi
  target_label="$TARGET_NAME ($TARGET_HOST)"
  printf 'Install the relayer and console on %s? [y/N] ' "$target_label"
  IFS= read -r answer
  case "$answer" in
    y | Y | yes | YES | Yes) ;;
    *) printf 'Installation cancelled.\n'; return 0 ;;
  esac
  console_installed="$(jq -r '.consoleInstalled' "$DISCOVERY_FILE")"
  console_password_reset=true
  if [[ "$console_installed" == true && "${RELAYER_CONSOLE_PASSWORD_RESET:-false}" != "true" ]]; then
    console_password_reset=false
  fi
  if ! read_console_password console_password "$console_password_reset"; then
    die "console password entry was interrupted; installation was not started"
  fi

  # Verify target artifacts and capabilities before any backup or VM mutation.
  prepare_release true
  role_operation=install
  current_state_schema=1
  if [[ "$(jq -r '.keystoreExists and .releaseMetadataExists' "$DISCOVERY_FILE")" == true ]]; then
    role_operation=reapply
    current_state_schema="$(jq -r '.recordedRelease.stateSchema // 1' "$DISCOVERY_FILE")"
  fi
  resolve_install_scanner_settings "$role_operation" "$DISCOVERY_FILE"
  effective_scanner_poll="$EFFECTIVE_RELAYER_SCANNER_POLL_SECONDS"
  effective_scanner_start="$EFFECTIVE_RELAYER_SCANNER_START_BLOCK"
  if [[ "$role_operation" == reapply ]]; then
    printf 'Existing Relayer state was found; creating a recovery backup before reapplying.\n'
    run_manage_playbook backup
  fi
  bundle_dir="$WORK_DIR/generated"
  setup_result="$WORK_DIR/setup-result.json"
  generate_relayer_setup_bundle "$console_password" "$bundle_dir" "$setup_result"
  console_password=""

  tls_identity_exists="$(jq -r '.tlsIdentityExists' "$DISCOVERY_FILE")"
  tls_pair_exists="$(jq -r '.tlsPairExists' "$DISCOVERY_FILE")"
  if [[ "$tls_identity_exists" == true ]]; then
    p2p_node_id="$(jq -r '.p2pNodeId' "$DISCOVERY_FILE")"
    tls_certificate_sha256="$(jq -r '.tlsCertificateSha256' "$DISCOVERY_FILE")"
    printf 'Reusing permanent Relayer P2P NodeID: %s\n' "$p2p_node_id"
  elif [[ "$tls_pair_exists" == true ]]; then
    die "the retained TLS certificate/key pair predates permanent identity metadata; restore a matching identity.json or explicitly purge the obsolete test identity before a fresh install"
  else
    p2p_node_id="$(jq -r '.p2pNodeId' "$setup_result")"
    tls_certificate_sha256="$(jq -r '.tlsCertificateSha256' "$setup_result")"
    identity_file="$WORK_DIR/identity.json"
    write_identity_metadata "$p2p_node_id" "$tls_certificate_sha256" "$identity_file"
    printf 'Staging permanent Relayer P2P NodeID before runtime installation: %s\n' "$p2p_node_id"
    stage_relayer_identity \
      "$p2p_node_id" \
      "$tls_certificate_sha256" \
      "$(jq -r '.tlsCertFile' "$setup_result")" \
      "$(jq -r '.tlsKeyFile' "$setup_result")" \
      "$identity_file"
  fi

  if ! protocol_privacy_gate "$p2p_node_id" "$DISCOVERY_FILE"; then
    return 1
  fi
  if ! peer_visibility_gate "$DISCOVERY_FILE"; then
    return 1
  fi

  setup_config="$(jq -r '.configFile' "$setup_result")"
  rewritten_config="$WORK_DIR/config.json"
  # The scanner block is written here rather than left to the daemon's defaults because
  # this file is regenerated on every install and reapply — a hand-edit on the host would
  # be silently reverted the next time anyone runs `make relayer`.
  #
  # NOTE: relayerd rejects ANY config key it does not recognise (UnmarshalExact) and
  # refuses to boot. So this block may only be emitted against a release that parses it.
  # Capability resolution happens only after the checksummed archive is extracted;
  # legacy releases (including rc.8) omit this key entirely.
  jq \
    --arg keystore /var/lib/relayerd/keystore.json \
    --arg tls_cert /var/lib/relayerd/tls/staker.crt \
    --arg tls_key /var/lib/relayerd/tls/staker.key \
    --arg database /var/lib/relayerd/relayer.db \
    --arg backups /var/backups/relayerd \
    --argjson scanner_enabled "$RESOLVED_RELAYER_SCANNER_ENABLED" \
    --argjson scanner_poll "$effective_scanner_poll" \
    --argjson scanner_start_block "$effective_scanner_start" \
    '."tls-cert-path" = $tls_cert |
     ."tls-key-path" = $tls_key |
     ."bbolt-path" = $database |
     ."api-listen-addr" = "127.0.0.1:8081" |
     ."key-source"."backend" = "encrypted-file" |
     ."key-source"."encrypted-file" = $keystore |
     ."state-backup" = {"dir": $backups, "interval-seconds": 300} |
     (if $scanner_enabled then
        ."scanner" = {
          "enabled": true,
          "poll-interval-seconds": $scanner_poll,
          "start-block": $scanner_start_block,
          "pause-file": "/etc/relayerd/scanner-pause"
        }
      else . end)' \
    "$setup_config" >"$rewritten_config"

  funding_file="$WORK_DIR/funding.json"
  jq --arg manager "$(jq -r '.managerAddress' "$METADATA_FILE")" \
    --arg validator_manager "$(jq -r '.validatorManagerAddress' "$METADATA_FILE")" \
    --arg p2p_node_id "$p2p_node_id" \
    --arg tls_certificate_sha256 "$tls_certificate_sha256" \
    '{version, pChainAddress, evmAddress, networkId, subnetId, blockchainId, evmChainId, chainName,
      managerAddress: $manager, validatorManagerAddress: $validator_manager,
      p2pNodeId: $p2p_node_id, tlsCertificateSha256: $tls_certificate_sha256}' \
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
    --arg p2p_node_id "$p2p_node_id" \
    --arg tls_certificate_sha256 "$tls_certificate_sha256" \
    --arg safe_address "$safe_address" \
    --argjson password_reset "$console_password_reset" \
    --argjson preserve "$preserve_keystore" \
    --argjson safe_enabled "$safe_enabled" \
    --arg role_operation "$role_operation" \
    --argjson target_config_schema "$RELEASE_CONFIG_SCHEMA" \
    --argjson current_state_schema "$current_state_schema" \
    --argjson target_state_schema "$RELEASE_STATE_SCHEMA" \
    --argjson target_min_readable_state_schema "$RELEASE_MIN_READABLE_STATE_SCHEMA" \
    --argjson target_min_automatic_rollback_state_schema "$RELEASE_MIN_AUTOMATIC_ROLLBACK_STATE_SCHEMA" \
    --argjson scanner_enabled "$RESOLVED_RELAYER_SCANNER_ENABLED" \
    --argjson scanner_poll "$effective_scanner_poll" \
    --argjson scanner_start_block "$effective_scanner_start" \
    '{
      acp_relayer_discovered_target: $target,
      acp_relayer_operation: $role_operation,
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
      acp_relayer_console_password_reset: $password_reset,
      acp_relayer_funding_src: $funding,
      acp_relayer_expected_p2p_node_id: $p2p_node_id,
      acp_relayer_expected_tls_certificate_sha256: $tls_certificate_sha256,
      acp_relayer_preserve_keystore: $preserve,
      acp_relayer_safe_enabled: $safe_enabled,
      acp_relayer_safe_address: $safe_address,
      acp_relayer_target_config_schema: $target_config_schema,
      acp_relayer_current_state_schema: $current_state_schema,
      acp_relayer_target_state_schema: $target_state_schema,
      acp_relayer_target_min_readable_state_schema: $target_min_readable_state_schema,
      acp_relayer_target_min_automatic_rollback_state_schema: $target_min_automatic_rollback_state_schema,
      acp_relayer_scanner_enabled: $scanner_enabled,
      acp_relayer_scanner_poll_seconds: $scanner_poll,
      acp_relayer_scanner_start_block: $scanner_start_block
    }' >"$vars_file"

  (
    cd "$ROOT_DIR/ansible" || exit 1
    ANSIBLE_CONFIG="$ROOT_DIR/ansible/ansible.cfg" \
      ansible-playbook -i "$INVENTORY_FILE" playbooks/l1/deploy-relayer.yml -e "@$vars_file"
  )
}

run_upgrade() {
  local vars_file private_count current_state_schema effective_scanner_poll effective_scanner_start
  run_preflight
  private_count="$(jq '[.validatorPrivacy[] | select(.validatorOnly)] | length' "$DISCOVERY_FILE")"
  if ((private_count > 0)) && [[ "$(jq -r '.tlsIdentityExists' "$DISCOVERY_FILE")" != true ]]; then
    die "protocol-private upgrades require retained permanent identity metadata; restore identity.json from the matching backup before upgrading"
  fi
  if ! protocol_privacy_gate "$(jq -r '.p2pNodeId' "$DISCOVERY_FILE")" "$DISCOVERY_FILE" \
    "The upgrade was not started. Update every validator, then rerun make relayer-upgrade."; then
    return 1
  fi
  prepare_release false
  current_state_schema="$(jq -r '.recordedRelease.stateSchema // 1' "$DISCOVERY_FILE")"
  resolve_install_scanner_settings upgrade "$DISCOVERY_FILE"
  effective_scanner_poll="$EFFECTIVE_RELAYER_SCANNER_POLL_SECONDS"
  effective_scanner_start="$EFFECTIVE_RELAYER_SCANNER_START_BLOCK"
  run_manage_playbook backup
  vars_file="$WORK_DIR/upgrade-vars.json"
  jq -n \
    --arg target "$TARGET_NAME" \
    --arg version "$RELAYER_VERSION" \
    --arg binary "$RELEASE_BINARY" \
    --arg restore_binary "$RELEASE_RESTORE" \
    --arg image "$CONSOLE_IMAGE" \
    --arg blockchain "$(jq -r '.blockchainId' "$METADATA_FILE")" \
    --argjson current_state_schema "$current_state_schema" \
    --argjson target_config_schema "$RELEASE_CONFIG_SCHEMA" \
    --argjson target_state_schema "$RELEASE_STATE_SCHEMA" \
    --argjson target_min_readable_state_schema "$RELEASE_MIN_READABLE_STATE_SCHEMA" \
    --argjson target_min_automatic_rollback_state_schema "$RELEASE_MIN_AUTOMATIC_ROLLBACK_STATE_SCHEMA" \
    --argjson scanner_enabled "$RESOLVED_RELAYER_SCANNER_ENABLED" \
    --argjson scanner_poll "$effective_scanner_poll" \
    --argjson scanner_start_block "$effective_scanner_start" \
    '{
      acp_relayer_discovered_target: $target,
      acp_relayer_operation: "upgrade",
      acp_relayer_version: $version,
      acp_relayer_binary_local_src: $binary,
      acp_relayer_restore_binary_local_src: $restore_binary,
      acp_relayer_console_image: $image,
      acp_relayer_blockchain_id: $blockchain,
      acp_relayer_current_state_schema: $current_state_schema,
      acp_relayer_target_config_schema: $target_config_schema,
      acp_relayer_target_state_schema: $target_state_schema,
      acp_relayer_target_min_readable_state_schema: $target_min_readable_state_schema,
      acp_relayer_target_min_automatic_rollback_state_schema: $target_min_automatic_rollback_state_schema,
      acp_relayer_scanner_enabled: $scanner_enabled,
      acp_relayer_scanner_poll_seconds: $scanner_poll,
      acp_relayer_scanner_start_block: $scanner_start_block
    }' >"$vars_file"
  (
    cd "$ROOT_DIR/ansible" || exit 1
    ANSIBLE_CONFIG="$ROOT_DIR/ansible/ansible.cfg" \
      ansible-playbook -i "$INVENTORY_FILE" playbooks/l1/deploy-relayer.yml -e "@$vars_file"
  )
}
