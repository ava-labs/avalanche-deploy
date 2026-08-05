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
  console_installed="$(jq -r '.consoleInstalled' "$DISCOVERY_FILE")"
  console_password_reset=true
  if [[ "$console_installed" == true && "${RELAYER_CONSOLE_PASSWORD_RESET:-false}" != "true" ]]; then
    console_password_reset=false
  fi
  if ! read_console_password console_password "$console_password_reset"; then
    die "console password entry was interrupted; installation was not started"
  fi

  if [[ "$(jq -r '.keystoreExists and .releaseMetadataExists' "$DISCOVERY_FILE")" == true ]]; then
    printf 'Existing Relayer state was found; creating a recovery backup before reapplying.\n'
    run_manage_playbook backup
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
    --argjson password_reset "$console_password_reset" \
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
      acp_relayer_console_password_reset: $password_reset,
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
