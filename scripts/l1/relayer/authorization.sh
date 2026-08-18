# shellcheck shell=bash
# Protocol-private authorization reporting and managed validator updates.

RELAYER_AUTHORIZATION_RUNBOOK_URL="https://github.com/ava-labs/avalanche-deploy/blob/main/docs/l1/RELAYER-AUTHORIZATION.md"
RELAYER_MANUAL_AUTHORIZATION_URL="${RELAYER_AUTHORIZATION_RUNBOOK_URL}#manual-or-external-authorization"

required_protocol_nodes() {
  local p2p_node_id="$1"
  local discovery_file="$2"
  local preserve_current="${3:-true}"
  jq -c --arg node_id "$p2p_node_id" --argjson preserve_current "$preserve_current" '
    ((if $node_id != "" then [{name: "Relayer", nodeId: $node_id}] else [] end)
     + (if $preserve_current and (.tlsIdentityExists // false) and
              (.p2pNodeId // "") != "" and (.p2pNodeId // "") != $node_id
        then [{name: "Current Relayer", nodeId: .p2pNodeId}]
        else []
        end)
     + [(.rpcNodes // [])[] | {name, nodeId}])
    | unique_by(.nodeId)
  ' "$discovery_file"
}

protocol_privacy_counts() {
  local discovery_file="$1"
  jq -r '[(.validatorPrivacy | length), ([.validatorPrivacy[] | select(.validatorOnly)] | length)] | @tsv' \
    "$discovery_file"
}

protocol_authorization_missing_count() {
  local required_nodes="$1"
  local discovery_file="$2"
  jq --argjson required "$required_nodes" '
    [.validatorPrivacy[] as $validator
     | $required[] as $node
     | select($validator.allowedNodes | index($node.nodeId) | not)]
    | length
  ' "$discovery_file"
}

protocol_runtime_stale_count() {
  local discovery_file="$1"
  jq '[.validatorPrivacy[] | select(.validatorOnly and (.runtimeConfigFresh | not))] | length' \
    "$discovery_file"
}

print_protocol_authorization() {
  local p2p_node_id="$1"
  local discovery_file="$2"
  local required_nodes="${3:-}"
  if [[ -z "$required_nodes" ]]; then
    required_nodes="$(required_protocol_nodes "$p2p_node_id" "$discovery_file")"
  fi

  if [[ -n "$p2p_node_id" ]]; then
    printf 'Permanent Relayer P2P NodeID: %s\n' "$p2p_node_id"
  fi
  printf 'Required non-validator NodeIDs:\n'
  jq -r '.[] | "  - \(.name): \(.nodeId)"' <<<"$required_nodes"
  printf 'Missing allowlist entries:\n'
  if ! jq -er --argjson required "$required_nodes" '
    [.validatorPrivacy[] as $validator
     | $required[] as $node
     | select($validator.allowedNodes | index($node.nodeId) | not)
     | "  - \($validator.name): \($node.name) \($node.nodeId) (\($validator.source))"]
    | if length == 0 then empty else .[] end
  ' "$discovery_file"; then
    printf '  - none\n'
  fi
  printf 'Validators that require an AvalancheGo restart:\n'
  if ! jq -er '
    [.validatorPrivacy[]
     | select(.validatorOnly and (.runtimeConfigFresh | not))
     | "  - \(.name): running process predates \(.source)"]
    | if length == 0 then empty else .[] end
  ' "$discovery_file"; then
    printf '  - none\n'
  fi
  printf 'Required config shape: '
  jq -cn --argjson required "$required_nodes" \
    '{validatorOnly: true, allowedNodes: [$required[].nodeId]}'
  printf 'Authorization guide: %s\n' "$RELAYER_AUTHORIZATION_RUNBOOK_URL"
  printf 'AvalancheGo reference: https://build.avax.network/docs/nodes/chain-configs/avalanche-l1s/avalanche-l1-configs#allowednodes-string-list\n'
  printf 'Terraform/Ansible-managed option: make relayer-authorize\n'
  printf '  Avalanche Deploy updates the managed validator allowlists, performs rolling restarts, and verifies RPC peering.\n'
  printf 'Manual or external infrastructure: %s\n' "$RELAYER_MANUAL_AUTHORIZATION_URL"
  printf '  Follow that runbook when the L1 owner will apply and restart the validator configuration.\n'
}

protocol_privacy_gate() {
  local p2p_node_id="$1"
  local discovery_file="$2"
  local blocked_message="${3:-The permanent identity remains on rpc[0]. Authorize every validator, then rerun make relayer.}"
  local validator_count private_count missing_count stale_count required_nodes
  read -r validator_count private_count < <(protocol_privacy_counts "$discovery_file")

  if ((private_count == 0)); then
    printf 'Protocol privacy: disabled on all %s validator(s); NodeID authorization is not required.\n' "$validator_count"
    return 0
  fi
  if ((private_count != validator_count)); then
    printf 'ERROR: validatorOnly is inconsistent across the L1 validator set (%s of %s enabled).\n' \
      "$private_count" "$validator_count" >&2
    printf 'Apply one protocol-privacy policy to every validator before Relayer installation.\n' >&2
    jq -r '.validatorPrivacy[] | "  - \(.name): validatorOnly=\(.validatorOnly) (\(.source))"' \
      "$discovery_file" >&2
    return 1
  fi

  required_nodes="$(required_protocol_nodes "$p2p_node_id" "$discovery_file")"
  missing_count="$(protocol_authorization_missing_count "$required_nodes" "$discovery_file")"
  if ((missing_count > 0)); then
    printf 'ERROR: this protocol-private L1 does not authorize every required NodeID.\n' >&2
    print_protocol_authorization "$p2p_node_id" "$discovery_file" >&2
    printf '%s\n' "$blocked_message" >&2
    return 1
  fi
  stale_count="$(protocol_runtime_stale_count "$discovery_file")"
  if ((stale_count > 0)); then
    printf 'ERROR: protocol-private validator configuration has not been loaded by every running AvalancheGo process.\n' >&2
    print_protocol_authorization "$p2p_node_id" "$discovery_file" "$required_nodes" >&2
    printf 'Restart every listed validator or run make relayer-authorize.\n' >&2
    return 1
  fi

  printf 'Protocol privacy: all %s validator(s) authorize the permanent Relayer and managed RPC NodeIDs.\n' \
    "$validator_count"
}

peer_visibility_gate() {
  local discovery_file="$1"
  local missing_count
  missing_count="$(jq '(.missingValidatorPeers // []) | length' "$discovery_file")"
  if ((missing_count == 0)); then
    return 0
  fi

  printf 'ERROR: rpc[0] cannot see these validator peers:\n' >&2
  jq -r '(.missingValidatorPeers // [])[] | "  - \(.name): \(.nodeId)"' "$discovery_file" >&2
  printf 'The validator configuration can be correct while the running process is stale.\n' >&2
  printf 'Restart the affected validators or run make relayer-authorize.\n' >&2
  return 1
}

authorization_needed() {
  local p2p_node_id="$1"
  local discovery_file="$2"
  local validator_count private_count required_nodes missing_count missing_peer_count stale_count
  read -r validator_count private_count < <(protocol_privacy_counts "$discovery_file")
  ((private_count > 0)) || return 1
  ((private_count == validator_count)) || return 0
  required_nodes="$(required_protocol_nodes "$p2p_node_id" "$discovery_file")"
  missing_count="$(protocol_authorization_missing_count "$required_nodes" "$discovery_file")"
  missing_peer_count="$(jq '(.missingValidatorPeers // []) | length' "$discovery_file")"
  stale_count="$(protocol_runtime_stale_count "$discovery_file")"
  ((missing_count > 0 || missing_peer_count > 0 || stale_count > 0))
}

run_authorization() {
  local confirmed="${1:-false}"
  local override_node_id="${2:-}"
  local force="${3:-false}"
  local preserve_current="${4:-true}"
  local required_override="${5:-}"
  local validator_count private_count p2p_node_id required_nodes missing_peer_ids stale_validator_ids
  local vars_file run_id answer missing_count stale_count
  run_authorization_preflight
  read -r validator_count private_count < <(protocol_privacy_counts "$DISCOVERY_FILE")

  if ((private_count == 0)); then
    printf 'Protocol privacy is disabled on all %s validator(s). No authorization or restart is required.\n' \
      "$validator_count"
    return 0
  fi
  ((private_count == validator_count)) || \
    die "validatorOnly is inconsistent across the L1 validator set; this command made no changes"

  if [[ -n "$required_override" ]]; then
    jq -e '
      type == "array" and length > 0 and
      all(.[]; (.name | type) == "string" and (.nodeId | startswith("NodeID-")))
    ' <<<"$required_override" >/dev/null || die "the managed authorization NodeID plan is invalid"
    p2p_node_id="$override_node_id"
    required_nodes="$(jq -c 'unique_by(.nodeId)' <<<"$required_override")"
  elif [[ -n "$override_node_id" ]]; then
    p2p_node_id="$override_node_id"
  else
    [[ "$(jq -r '.tlsIdentityExists' "$DISCOVERY_FILE")" == true ]] || \
      die "the permanent Relayer identity is not staged; run make relayer-prepare first"
    p2p_node_id="$(jq -r '.p2pNodeId' "$DISCOVERY_FILE")"
  fi
  if [[ -n "$p2p_node_id" ]]; then
    [[ "$p2p_node_id" == NodeID-* ]] || die "the selected Relayer NodeID is invalid"
  elif [[ -z "$required_override" ]]; then
    die "the selected Relayer NodeID is invalid"
  fi
  if [[ -z "${required_nodes:-}" ]]; then
    required_nodes="$(required_protocol_nodes "$p2p_node_id" "$DISCOVERY_FILE" "$preserve_current")"
  fi

  print_protocol_authorization "$p2p_node_id" "$DISCOVERY_FILE" "$required_nodes"
  missing_count="$(protocol_authorization_missing_count "$required_nodes" "$DISCOVERY_FILE")"
  stale_count="$(protocol_runtime_stale_count "$DISCOVERY_FILE")"
  if ((missing_count == 0 && stale_count == 0)) && \
    [[ "$(jq '(.missingValidatorPeers // []) | length' "$DISCOVERY_FILE")" == 0 ]] && \
    [[ "$force" != true ]]; then
    printf 'Every required NodeID is authorized and rpc[0] sees every validator. No changes were made.\n'
    return 0
  fi

  if [[ "$confirmed" != true ]]; then
    printf 'Update the managed validator allowlists and restart only affected validators? [y/N] '
    IFS= read -r answer
    case "$answer" in
      y | Y | yes | YES | Yes) ;;
      *) printf 'Authorization cancelled; no changes were made.\n'; return 0 ;;
    esac
  fi

  missing_peer_ids="$(jq -c '[.missingValidatorPeers[]?.nodeId]' "$DISCOVERY_FILE")"
  stale_validator_ids="$(jq -c \
    '[.validatorPrivacy[] | select(.validatorOnly and (.runtimeConfigFresh | not)) | .nodeId]' \
    "$DISCOVERY_FILE")"
  run_id="$(date -u +%Y%m%dT%H%M%SZ)"
  vars_file="$WORK_DIR/authorization-vars.json"
  jq -n \
    --arg subnet "$(jq -r '.subnetId' "$METADATA_FILE")" \
    --arg blockchain "$(jq -r '.blockchainId' "$METADATA_FILE")" \
    --arg run_id "$run_id" \
    --argjson required "$required_nodes" \
    --argjson missing_peer_ids "$missing_peer_ids" \
    --argjson stale_validator_ids "$stale_validator_ids" \
    '{
      acp_relayer_subnet_id: $subnet,
      acp_relayer_blockchain_id: $blockchain,
      acp_relayer_required_nodes: $required,
      acp_relayer_missing_validator_peer_ids: $missing_peer_ids,
      acp_relayer_stale_validator_ids: $stale_validator_ids,
      acp_relayer_authorization_run_id: $run_id
    }' >"$vars_file"

  (
    cd "$ROOT_DIR/ansible" || exit 1
    ANSIBLE_CONFIG="$ROOT_DIR/ansible/ansible.cfg" \
      ansible-playbook -i "$INVENTORY_FILE" playbooks/l1/authorize-relayer.yml -e "@$vars_file"
  )

  run_authorization_preflight
  missing_count="$(protocol_authorization_missing_count "$required_nodes" "$DISCOVERY_FILE")"
  stale_count="$(protocol_runtime_stale_count "$DISCOVERY_FILE")"
  ((missing_count == 0)) || die "managed authorization finished without a complete effective allowlist"
  ((stale_count == 0)) || die "managed authorization finished before every validator loaded its effective configuration"
  peer_visibility_gate "$DISCOVERY_FILE" || \
    die "managed authorization finished before RPC-to-validator peering recovered"
  if [[ -n "$required_override" ]]; then
    printf 'Managed validator authorization state is synchronized.\n'
  else
    printf 'Managed Relayer authorization is complete. Run make relayer for the full readiness check and installation.\n'
  fi
}

run_authorization_cleanup() {
  local retained_relayer_node_id="${1:-}"
  local required_nodes validator_count private_count
  run_authorization_preflight
  read -r validator_count private_count < <(protocol_privacy_counts "$DISCOVERY_FILE")
  ((private_count > 0)) || return 0
  ((private_count == validator_count)) || \
    die "validatorOnly is inconsistent; temporary restore authorization was not cleaned"
  required_nodes="$(required_protocol_nodes "$retained_relayer_node_id" "$DISCOVERY_FILE" false)"
  run_authorization true "$retained_relayer_node_id" true false "$required_nodes"
}

offer_managed_authorization() {
  local p2p_node_id="$1"
  local answer
  print_protocol_authorization "$p2p_node_id" "$DISCOVERY_FILE"
  printf 'Run managed authorization now and continue this installation after all checks pass? [y/N] '
  IFS= read -r answer
  case "$answer" in
    y | Y | yes | YES | Yes) run_authorization true "$p2p_node_id" ;;
    *)
      printf 'Installation stopped.\n'
      printf 'Terraform/Ansible-managed authorization: make relayer-authorize\n'
      printf 'Manual or external authorization: %s\n' "$RELAYER_MANUAL_AUTHORIZATION_URL"
      return 1
      ;;
  esac
}
