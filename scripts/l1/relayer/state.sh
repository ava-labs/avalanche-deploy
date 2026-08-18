# shellcheck shell=bash
# Terraform, inventory, L1 metadata, target, and SSH state discovery.

managed_info_rpc_url() {
  case "$1" in
    fuji) printf '%s\n' "https://api.avax-test.network" ;;
    mainnet) printf '%s\n' "https://api.avax.network" ;;
    *) return 1 ;;
  esac
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


ssh_target() {
  local user
  local port
  local key_file
  local destination
  local host_key_checking
  local -a args
  user="$(jq -r '.rpc[0].user' "$INVENTORY_SUMMARY")"
  port="$(jq -r '.rpc[0].port' "$INVENTORY_SUMMARY")"
  key_file="$(jq -r '.rpc[0].privateKeyFile' "$INVENTORY_SUMMARY")"
  destination="$TARGET_HOST"
  [[ -n "$user" ]] && destination="$user@$destination"
  # Default matches ansible.cfg host_key_checking = False and the
  # StrictHostKeyChecking=no that every Terraform-generated inventory emits, so a
  # rebuilt rpc[0] with a stale known_hosts entry stays reachable here exactly as
  # it is for every ansible command. Export RELAYER_SSH_HOST_KEY_CHECKING=accept-new
  # to opt into refusing a changed host key.
  host_key_checking="${RELAYER_SSH_HOST_KEY_CHECKING:-no}"
  case "$host_key_checking" in
    accept-new | yes | no | ask) ;;
    *) die "RELAYER_SSH_HOST_KEY_CHECKING must be accept-new, yes, no, or ask" ;;
  esac
  args=(-o "StrictHostKeyChecking=$host_key_checking" -o ServerAliveInterval=30 -o ServerAliveCountMax=20 -p "$port")
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
