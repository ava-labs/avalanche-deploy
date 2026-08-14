#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=scripts/l1/relayer.sh
source scripts/l1/relayer.sh

fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
node_id="NodeID-RelayerPrivacyFixture"
rpc_node_id="NodeID-RpcPrivacyFixture"

write_fixture() {
  local name="$1"
  local first_private="$2"
  local second_private="$3"
  local first_allowed="$4"
  local second_allowed="$5"
  jq -n \
    --arg node_id "$node_id" \
    --arg rpc_node_id "$rpc_node_id" \
    --argjson first_private "$first_private" \
    --argjson second_private "$second_private" \
    --argjson first_allowed "$first_allowed" \
    --argjson second_allowed "$second_allowed" \
    '{rpcNodes: [{name: "rpc-archive-1", nodeId: $rpc_node_id}], validatorPrivacy: [
      {
        name: "validator-1",
        nodeId: "NodeID-Validator1",
        validatorOnly: $first_private,
        allowedNodes: (if $first_allowed then [$node_id, $rpc_node_id] else [] end),
        runtimeConfigFresh: true,
        source: "/etc/avalanchego/subnets/test.json"
      },
      {
        name: "validator-2",
        nodeId: "NodeID-Validator2",
        validatorOnly: $second_private,
        allowedNodes: (if $second_allowed then [$node_id, $rpc_node_id] else [] end),
        runtimeConfigFresh: true,
        source: "/etc/avalanchego/subnets/test.json"
      }
    ]}' >"$fixture_dir/$name.json"
}

write_fixture open false false false false
write_fixture private-allowed true true true true
write_fixture private-missing true true true false
write_fixture mixed true false true false
jq --arg node_id "$node_id" \
  '.validatorPrivacy[].allowedNodes = [$node_id]' \
  "$fixture_dir/private-allowed.json" >"$fixture_dir/private-rpc-missing.json"
jq '.tlsIdentityExists = true | .p2pNodeId = "NodeID-CurrentRelayer"' \
  "$fixture_dir/private-allowed.json" >"$fixture_dir/restore-rotation.json"
jq '.validatorPrivacy[1].runtimeConfigFresh = false' \
  "$fixture_dir/private-allowed.json" >"$fixture_dir/private-stale-runtime.json"

protocol_privacy_gate "$node_id" "$fixture_dir/open.json" >"$fixture_dir/open.out" 2>&1
grep -Fq 'authorization is not required' "$fixture_dir/open.out"

protocol_privacy_gate "$node_id" "$fixture_dir/private-allowed.json" >"$fixture_dir/allowed.out" 2>&1
grep -Fq 'all 2 validator(s) authorize the permanent Relayer and managed RPC NodeIDs' "$fixture_dir/allowed.out"

if protocol_privacy_gate "$node_id" "$fixture_dir/private-stale-runtime.json" >"$fixture_dir/stale.out" 2>&1; then
  printf 'Expected a stale validator runtime failure\n' >&2
  exit 1
fi
grep -Fq 'configuration has not been loaded by every running AvalancheGo process' "$fixture_dir/stale.out"
grep -Fq 'validator-2: running process predates' "$fixture_dir/stale.out"
authorization_needed "$node_id" "$fixture_dir/private-stale-runtime.json"

if protocol_privacy_gate "$node_id" "$fixture_dir/private-rpc-missing.json" >"$fixture_dir/rpc-missing.out" 2>&1; then
  printf 'Expected a protocol-private missing-RPC-allowlist failure\n' >&2
  exit 1
fi
grep -Fq "rpc-archive-1: $rpc_node_id" "$fixture_dir/rpc-missing.out"
grep -Fq 'Required non-validator NodeIDs' "$fixture_dir/rpc-missing.out"

if protocol_privacy_gate "$node_id" "$fixture_dir/private-missing.json" >"$fixture_dir/missing.out" 2>&1; then
  printf 'Expected a protocol-private missing-allowlist failure\n' >&2
  exit 1
fi
grep -Fq 'this protocol-private L1 does not authorize every required NodeID' "$fixture_dir/missing.out"
grep -Fq 'validator-2' "$fixture_dir/missing.out"
grep -Fq 'Authorization guide: https://github.com/ava-labs/avalanche-deploy/blob/main/docs/l1/RELAYER-AUTHORIZATION.md' "$fixture_dir/missing.out"
grep -Fq 'Terraform/Ansible-managed option: make relayer-authorize' "$fixture_dir/missing.out"
grep -Fq 'Manual or external infrastructure: https://github.com/ava-labs/avalanche-deploy/blob/main/docs/l1/RELAYER-AUTHORIZATION.md#manual-or-external-authorization' "$fixture_dir/missing.out"
grep -Fq 'AvalancheGo reference: https://build.avax.network/docs/nodes/chain-configs/avalanche-l1s/avalanche-l1-configs#allowednodes-string-list' "$fixture_dir/missing.out"

if protocol_privacy_gate "$node_id" "$fixture_dir/mixed.json" >"$fixture_dir/mixed.out" 2>&1; then
  printf 'Expected an inconsistent validatorOnly failure\n' >&2
  exit 1
fi
grep -Fq 'validatorOnly is inconsistent' "$fixture_dir/mixed.out"
grep -Fq 'Apply one protocol-privacy policy to every validator' "$fixture_dir/mixed.out"

required_protocol_nodes "NodeID-RestoredRelayer" "$fixture_dir/restore-rotation.json" \
  >"$fixture_dir/restore-required.json"
jq -e '
  map(.nodeId)
  | index("NodeID-CurrentRelayer") != null and
    index("NodeID-RestoredRelayer") != null and
    index("NodeID-RpcPrivacyFixture") != null
' "$fixture_dir/restore-required.json" >/dev/null

required_protocol_nodes "NodeID-RestoredRelayer" "$fixture_dir/restore-rotation.json" false \
  >"$fixture_dir/restore-cleanup-required.json"
jq -e '
  map(.nodeId)
  | index("NodeID-CurrentRelayer") == null and
    index("NodeID-RestoredRelayer") != null and
    index("NodeID-RpcPrivacyFixture") != null
' "$fixture_dir/restore-cleanup-required.json" >/dev/null

required_protocol_nodes "" "$fixture_dir/restore-rotation.json" false \
  >"$fixture_dir/failed-restore-cleanup-required.json"
jq -e '
  map(.nodeId) == ["NodeID-RpcPrivacyFixture"]
' "$fixture_dir/failed-restore-cleanup-required.json" >/dev/null

printf 'Relayer protocol-privacy fixture checks passed\n'
