#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=scripts/l1/relayer.sh
source scripts/l1/relayer.sh

fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
node_id="NodeID-RelayerPrivacyFixture"

write_fixture() {
  local name="$1"
  local first_private="$2"
  local second_private="$3"
  local first_allowed="$4"
  local second_allowed="$5"
  jq -n \
    --arg node_id "$node_id" \
    --argjson first_private "$first_private" \
    --argjson second_private "$second_private" \
    --argjson first_allowed "$first_allowed" \
    --argjson second_allowed "$second_allowed" \
    '{validatorPrivacy: [
      {
        name: "validator-1",
        nodeId: "NodeID-Validator1",
        validatorOnly: $first_private,
        allowedNodes: (if $first_allowed then [$node_id] else [] end),
        source: "/etc/avalanchego/subnets/test.json"
      },
      {
        name: "validator-2",
        nodeId: "NodeID-Validator2",
        validatorOnly: $second_private,
        allowedNodes: (if $second_allowed then [$node_id] else [] end),
        source: "/etc/avalanchego/subnets/test.json"
      }
    ]}' >"$fixture_dir/$name.json"
}

write_fixture open false false false false
write_fixture private-allowed true true true true
write_fixture private-missing true true true false
write_fixture mixed true false true false

protocol_privacy_gate "$node_id" "$fixture_dir/open.json" >"$fixture_dir/open.out" 2>&1
grep -Fq 'allowlisting is not required' "$fixture_dir/open.out"

protocol_privacy_gate "$node_id" "$fixture_dir/private-allowed.json" >"$fixture_dir/allowed.out" 2>&1
grep -Fq 'all 2 validator(s) allow' "$fixture_dir/allowed.out"

if protocol_privacy_gate "$node_id" "$fixture_dir/private-missing.json" >"$fixture_dir/missing.out" 2>&1; then
  printf 'Expected a protocol-private missing-allowlist failure\n' >&2
  exit 1
fi
grep -Fq 'ALL existing L1 validators' "$fixture_dir/missing.out"
grep -Fq 'validator-2' "$fixture_dir/missing.out"
grep -Fq 'https://build.avax.network/docs/nodes/configure/avalanche-l1-configs#allowednodes-string-list' "$fixture_dir/missing.out"

if protocol_privacy_gate "$node_id" "$fixture_dir/mixed.json" >"$fixture_dir/mixed.out" 2>&1; then
  printf 'Expected an inconsistent validatorOnly failure\n' >&2
  exit 1
fi
grep -Fq 'validatorOnly is inconsistent' "$fixture_dir/mixed.out"
grep -Fq 'Every validator must enforce the same protocol-privacy policy' "$fixture_dir/mixed.out"

printf 'Relayer protocol-privacy fixture checks passed\n'
