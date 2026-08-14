#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/l1/relayer.sh
source "$ROOT_DIR/scripts/l1/relayer.sh"

fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT

fail() {
  printf 'Relayer release capability fixture failed: %s\n' "$*" >&2
  exit 1
}

write_capabilities() {
  local path="$1"
  local scanner="$2"
  printf '%s\n' \
    '{' \
    '  "schemaVersion": 1,' \
    '  "configSchema": 2,' \
    '  "stateSchema": 2,' \
    '  "minimumReadableStateSchema": 1,' \
    '  "minimumAutomaticRollbackStateSchema": 2,' \
    "  \"capabilities\": {\"scannerConfig\": $scanner}" \
    '}' >"$path"
}

RELAYER_VERSION=v0.1.0-rc.8
RELAYER_SCANNER_ENABLED=auto
RELEASE_CAPABILITIES="$fixture_dir/legacy-does-not-exist.json"
resolve_release_capabilities
[[ "$RESOLVED_RELAYER_SCANNER_ENABLED" == false ]] || fail "legacy auto policy enabled scanner"
[[ "$RELEASE_CONFIG_SCHEMA" == 1 && "$RELEASE_STATE_SCHEMA" == 1 ]] || fail "legacy schema defaults changed"

RELAYER_VERSION=v0.1.0-rc.9
RELAYER_SCANNER_ENABLED=auto
RELEASE_CAPABILITIES="$fixture_dir/scanner.json"
write_capabilities "$RELEASE_CAPABILITIES" true
resolve_release_capabilities
[[ "$RESOLVED_RELAYER_SCANNER_ENABLED" == true ]] || fail "scanner-capable auto policy did not enable scanner"
[[ "$RELEASE_MIN_AUTOMATIC_ROLLBACK_STATE_SCHEMA" == 2 ]] || fail "automatic rollback floor was not parsed"

RELAYER_VERSION=v0.1.0-rc.8
RELAYER_SCANNER_ENABLED=true
RELEASE_CAPABILITIES="$fixture_dir/legacy-does-not-exist.json"
if (resolve_release_capabilities) >"$fixture_dir/explicit-legacy.out" 2>&1; then
  fail "explicit scanner=true accepted a legacy release"
fi
grep -Fq 'legacy/incompatible' "$fixture_dir/explicit-legacy.out" || fail "legacy refusal was not actionable"

RELAYER_VERSION=v0.1.0-rc.9
RELAYER_SCANNER_ENABLED=auto
RELEASE_CAPABILITIES="$fixture_dir/malformed.json"
printf '%s\n' '{"schemaVersion":1,"capabilities":{"scannerConfig":true}}' >"$RELEASE_CAPABILITIES"
if (resolve_release_capabilities) >"$fixture_dir/malformed.out" 2>&1; then
  fail "malformed CAPABILITIES.json was accepted"
fi
grep -Fq 'CAPABILITIES.json is malformed' "$fixture_dir/malformed.out" || fail "malformed manifest refusal was not actionable"

printf '%s\n' '{"schemaVersion":1,"configSchema":1.5,"stateSchema":2.5,"minimumReadableStateSchema":0,"minimumAutomaticRollbackStateSchema":-1,"capabilities":{"scannerConfig":true}}' >"$RELEASE_CAPABILITIES"
if (resolve_release_capabilities) >"$fixture_dir/fractional.out" 2>&1; then
  fail "non-positive/fractional release schemas were accepted"
fi

RELAYER_SCANNER_ENABLED=false
RELEASE_CAPABILITIES="$fixture_dir/scanner.json"
resolve_release_capabilities
[[ "$RESOLVED_RELAYER_SCANNER_ENABLED" == false ]] || fail "explicit false did not omit scanner"

discovery="$fixture_dir/discovery.json"
jq -n '{
  daemonInstalled: true,
  existingScanner: {
    "enabled": true,
    "poll-interval-seconds": 9,
    "start-block": 1234,
    "pause-file": "/etc/relayerd/scanner-pause"
  },
  recordedRelease: {
    configSchema: 2,
    stateSchema: 2,
    minimumReadableStateSchema: 1
  }
}' >"$discovery"

RESOLVED_RELAYER_SCANNER_ENABLED=true
RELAYER_SCANNER_POLL_SECONDS=5
RELAYER_SCANNER_START_BLOCK=0
RELAYER_SCANNER_POLL_SECONDS_EXPLICIT=""
RELAYER_SCANNER_START_BLOCK_EXPLICIT=""
resolve_install_scanner_settings reapply "$discovery"
[[ "$EFFECTIVE_RELAYER_SCANNER_POLL_SECONDS" == 9 ]] || fail "reapply lost existing scanner poll interval"
[[ "$EFFECTIVE_RELAYER_SCANNER_START_BLOCK" == 1234 ]] || fail "reapply lost existing scanner start block"

RELAYER_SCANNER_POLL_SECONDS=7
RELAYER_SCANNER_START_BLOCK=55
RELAYER_SCANNER_POLL_SECONDS_EXPLICIT=x
RELAYER_SCANNER_START_BLOCK_EXPLICIT=x
resolve_install_scanner_settings reapply "$discovery"
[[ "$EFFECTIVE_RELAYER_SCANNER_POLL_SECONDS" == 7 ]] || fail "explicit poll override was ignored"
[[ "$EFFECTIVE_RELAYER_SCANNER_START_BLOCK" == 55 ]] || fail "explicit start override was ignored"

legacy_scanner_discovery="$fixture_dir/legacy-scanner-discovery.json"
jq '.existingScanner = {}' "$discovery" >"$legacy_scanner_discovery"
derive_scanner_start_block() { printf '777\n'; }
RELAYER_SCANNER_POLL_SECONDS=5
RELAYER_SCANNER_START_BLOCK=0
RELAYER_SCANNER_POLL_SECONDS_EXPLICIT=""
RELAYER_SCANNER_START_BLOCK_EXPLICIT=""
resolve_install_scanner_settings reapply "$legacy_scanner_discovery"
[[ "$EFFECTIVE_RELAYER_SCANNER_START_BLOCK" == 777 ]] || fail "legacy reapply did not derive a scanner anchor"
resolve_install_scanner_settings upgrade "$legacy_scanner_discovery"
[[ "$EFFECTIVE_RELAYER_SCANNER_START_BLOCK" == 777 ]] || fail "rc8 upgrade did not derive a scanner anchor"

manifest="$fixture_dir/backup.manifest.json"
printf '%s\n' '{"configSchema":1,"stateSchema":1}' >"$manifest"
validate_restore_runtime_schema "$manifest" "$discovery" || fail "new runtime rejected a legacy backup"

printf '%s\n' '{"configSchema":2,"stateSchema":2}' >"$manifest"
legacy_discovery="$fixture_dir/legacy-discovery.json"
printf '%s\n' '{"daemonInstalled":true,"recordedRelease":{"configSchema":1,"stateSchema":1,"minimumReadableStateSchema":1}}' >"$legacy_discovery"
if validate_restore_runtime_schema "$manifest" "$legacy_discovery" >"$fixture_dir/restore-new-to-legacy.out" 2>&1; then
  fail "legacy runtime accepted a schema-2 backup"
fi
grep -Fq 'backup config schema 2 is newer' "$fixture_dir/restore-new-to-legacy.out" || fail "restore incompatibility was not actionable"

validate_restore_runtime_schema "$manifest" "$discovery" || fail "matching schema restore was rejected"

removed_discovery="$fixture_dir/removed-discovery.json"
printf '%s\n' '{"daemonInstalled":false}' >"$removed_discovery"
RELAYER_VERSION=v0.1.0-rc.8
RELEASE_CONFIG_SCHEMA=1
RELEASE_STATE_SCHEMA=1
RELEASE_MIN_READABLE_STATE_SCHEMA=1
if validate_restore_runtime_schema "$manifest" "$removed_discovery" >/dev/null 2>&1; then
  fail "removed legacy target accepted a schema-2 backup for later reapply"
fi

printf 'Relayer release capability fixtures passed.\n'
