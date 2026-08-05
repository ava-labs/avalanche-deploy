# shellcheck shell=bash
# Local prerequisites plus immutable release discovery and verification.

run_prerequisites() {
  exec "$ROOT_DIR/scripts/shared/relayer-prereqs.sh" vm
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
  expected="$(awk -v name="$asset" '{file=$2; sub(/^\*/, "", file); if (file == name) print $1}' "$checksums")"
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
