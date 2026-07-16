#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ACTION="${1:-install}"
PINNED_RELAYER_VERSION="v0.1.0"
RELAYER_VERSION="${RELAYER_VERSION:-$PINNED_RELAYER_VERSION}"
L1_ENV="$ROOT_DIR/l1.env"
RELAYER_REPOSITORY="anishnar/Relayer"

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
CONSOLE_IMAGE=""

usage() {
  cat >&2 <<'EOF'
usage: scripts/l1/relayer.sh [install|access|status|logs|backup|upgrade|remove]

All infrastructure and L1 metadata are discovered from l1.env, Terraform state,
and the matching Ansible inventory. RELAYER_VERSION is the only advanced
override. Set PURGE=true with remove to permanently delete retained material.
EOF
  exit 2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required; install it and rerun"
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
}

run_preflight() {
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
      acp_relayer_expected_network_id: $network_id,
      acp_relayer_expected_evm_chain_id: $evm_chain_id,
      acp_relayer_validator_private_ips: $validator_private_ips
    }' >"$vars_file"

  (
    cd "$ROOT_DIR/ansible"
    ANSIBLE_CONFIG="$ROOT_DIR/ansible/ansible.cfg" \
      ansible-playbook -i "$INVENTORY_FILE" playbooks/l1/discover-relayer.yml -e "@$vars_file"
  )
  jq -e --arg target "$TARGET_NAME" \
    '.target == $target and (.peers | length > 0) and (.architecture | length > 0)' \
    "$DISCOVERY_FILE" >/dev/null || \
    die "Relayer discovery did not produce a complete result; inspect the Ansible preflight output above"
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
  curl -fL --retry 3 --retry-delay 1 \
    "https://github.com/$RELAYER_REPOSITORY/releases/download/$RELAYER_VERSION/$asset" \
    -o "$destination"
}

verify_archive() {
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
  verify_archive "$daemon_archive" "$checksums"
  tar -xzf "$daemon_archive" -C "$release_dir"
  daemon_bundle="$release_dir/${daemon_asset%.tar.gz}"
  RELEASE_BINARY="$daemon_bundle/relayerd"
  [[ -x "$RELEASE_BINARY" ]] || die "$daemon_asset does not contain an executable relayerd"

  image_file="$release_dir/relayer-console-image.txt"
  download_release_asset relayer-console-image.txt "$image_file"
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
    verify_archive "$setup_archive" "$checksums"
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
  jq -n --arg action "$action" --argjson purge "$purge" \
    '{relayer_manage_action: $action, relayer_purge: $purge}' >"$vars_file"
  (
    cd "$ROOT_DIR/ansible"
    ANSIBLE_CONFIG="$ROOT_DIR/ansible/ansible.cfg" \
      ansible-playbook -i "$INVENTORY_FILE" playbooks/l1/manage-relayer.yml -e "@$vars_file"
  )
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

  run_preflight
  target_label="$TARGET_NAME ($TARGET_HOST)"
  printf 'Install the relayer and console on %s? [y/N] ' "$target_label"
  IFS= read -r answer
  case "$answer" in
    y | Y | yes | YES | Yes) ;;
    *) printf 'Installation cancelled.\n'; return 0 ;;
  esac
  IFS= read -r -s -p 'Console password (press Enter for none): ' console_password
  printf '\n'

  prepare_release true
  bundle_dir="$WORK_DIR/generated"
  setup_result="$WORK_DIR/setup-result.json"
  setup_args=(
    --out "$bundle_dir"
    --l1-env "$L1_ENV"
    --pchain-rpc-url http://127.0.0.1:9650
    --info-rpc-url http://127.0.0.1:9650
    --evm-rpc-url "http://127.0.0.1:9650/ext/bc/$(jq -r '.blockchainId' "$METADATA_FILE")/rpc"
    --api-listen-addr 127.0.0.1:8080
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
     ."api-listen-addr" = "127.0.0.1:8080" |
     ."key-source"."backend" = "encrypted-file" |
     ."key-source"."encrypted-file" = $keystore |
     ."state-backup" = {"dir": $backups, "interval-seconds": 300}' \
    "$setup_config" >"$rewritten_config"

  funding_file="$WORK_DIR/funding.json"
  jq '{version, pChainAddress, evmAddress, networkId, subnetId, blockchainId, evmChainId, chainName}' \
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
  run_preflight
  run_manage_playbook backup
  prepare_release false
  vars_file="$WORK_DIR/upgrade-vars.json"
  jq -n \
    --arg target "$TARGET_NAME" \
    --arg version "$RELAYER_VERSION" \
    --arg binary "$RELEASE_BINARY" \
    --arg image "$CONSOLE_IMAGE" \
    --arg blockchain "$(jq -r '.blockchainId' "$METADATA_FILE")" \
    '{
      acp_relayer_discovered_target: $target,
      acp_relayer_operation: "upgrade",
      acp_relayer_version: $version,
      acp_relayer_binary_local_src: $binary,
      acp_relayer_console_image: $image,
      acp_relayer_blockchain_id: $blockchain
    }' >"$vars_file"
  (
    cd "$ROOT_DIR/ansible"
    ANSIBLE_CONFIG="$ROOT_DIR/ansible/ansible.cfg" \
      ansible-playbook -i "$INVENTORY_FILE" playbooks/l1/deploy-relayer.yml -e "@$vars_file"
  )
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
      printf 'Safe UI (when installed): http://127.0.0.1:3081\n'
      exec ssh "${args[@]}" -N \
        -L 3080:127.0.0.1:3080 \
        -L 9650:127.0.0.1:9650 \
        -L 3081:127.0.0.1:8080 \
        "$destination"
      ;;
    logs)
      exec ssh "${args[@]}" -t "$destination" \
        'sudo journalctl -u relayerd -u relayer-console -f --no-hostname'
      ;;
  esac
}

[[ $# -le 1 ]] || usage
[[ "$RELAYER_VERSION" =~ ^v[0-9A-Za-z][0-9A-Za-z.+-]*$ ]] || \
  die "RELAYER_VERSION must be a release tag such as v0.1.0"
case "$ACTION" in
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
    run_manage_playbook backup
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
