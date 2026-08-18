# shellcheck shell=bash
# Runtime status, backup, restore, and removal playbook workflows.

run_manage_playbook() {
  local action="$1"
  local purge="${2:-false}"
  local vars_file
  ensure_work_dir
  vars_file="$WORK_DIR/manage-vars.json"
  local backup_dir=""
  if [[ "$action" == backup ]]; then
    backup_dir="${RELAYER_BACKUP_DIR:-$ROOT_DIR/backups/relayer}"
    mkdir -p "$backup_dir"
    chmod 0700 "$backup_dir"
  fi
  jq -n --arg action "$action" --argjson purge "$purge" --arg backup_dir "$backup_dir" \
    '{relayer_manage_action: $action, relayer_purge: $purge, relayer_backup_fetch_dir: $backup_dir}' >"$vars_file"
  local playbook_status=0
  (
    cd "$ROOT_DIR/ansible" || exit 1
    ANSIBLE_CONFIG="$ROOT_DIR/ansible/ansible.cfg" \
      ansible-playbook -i "$INVENTORY_FILE" playbooks/l1/manage-relayer.yml -e "@$vars_file"
  ) || playbook_status=$?
  if [[ "$action" == backup ]]; then
    find "$backup_dir" -type f \( -name '*.tar.gz' -o -name '*.manifest.json' \) -exec chmod 0600 {} +
  fi
  return "$playbook_status"
}


run_reset_scanner() {
  local answer start_block
  run_preflight
  start_block="$(jq -r '.existingScanner["start-block"] // 0' "$DISCOVERY_FILE")"
  printf 'Reset the scanner cursor for a same-L1, same-manager rescan and discard its queued triggers on %s (%s)? [y/N] ' \
    "$TARGET_NAME" "$TARGET_HOST"
  IFS= read -r answer
  case "$answer" in
    y | Y | yes | YES | Yes) ;;
    *) printf 'Scanner reset cancelled; no changes made.\n'; return 0 ;;
  esac
  printf 'Creating a retained backup before scanner reset; this refuses if any operation records exist, and the next scan resumes from configured block %s.\n' \
    "$start_block"
  run_manage_playbook backup || return $?
  run_manage_playbook reset-scanner
}


validate_restore_archive_identity() {
  local backup="$1" manifest="$2"
  python3 - "$backup" "$manifest" <<'PY'
import hashlib
import json
import pathlib
import re
import ssl
import sys
import tarfile

backup_path, manifest_path = sys.argv[1:]
required = {
    "etc/relayerd/config.json",
    "etc/relayerd/funding.json",
    "etc/relayerd/identity.json",
    "etc/relayerd/release.json",
    "etc/relayerd/secrets/keystore-password",
    "etc/relayerd/secrets/console-session-secret",
    "etc/relayerd/secrets/console.env",
    "var/lib/relayerd/keystore.json",
    "var/lib/relayerd/relayer.db",
    "var/lib/relayerd/tls/staker.crt",
    "var/lib/relayerd/tls/staker.key",
}


def fail(message):
    raise SystemExit(message)


def cb58_encode(payload):
    alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    checked = payload + hashlib.sha256(payload).digest()[-4:]
    leading_zeroes = len(checked) - len(checked.lstrip(b"\0"))
    value = int.from_bytes(checked, "big")
    encoded = ""
    while value:
        value, remainder = divmod(value, 58)
        encoded = alphabet[remainder] + encoded
    return ("1" * leading_zeroes) + encoded


try:
    manifest = json.loads(pathlib.Path(manifest_path).read_text(encoding="utf-8"))
except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
    fail(f"backup manifest is unreadable: {error}")

try:
    with tarfile.open(backup_path, "r:gz") as archive:
        members = archive.getmembers()
        normalized_members = {}
        for member in members:
            name = member.name
            path = pathlib.PurePosixPath(name)
            if path.is_absolute() or ".." in path.parts:
                fail(f"unsafe archive member: {name}")
            if not (member.isfile() or member.isdir()):
                fail(f"unsupported link or special archive member: {name}")
            normalized = name.removeprefix("./")
            if normalized in normalized_members:
                fail(f"duplicate archive member: {normalized}")
            normalized_members[normalized] = member

        missing = sorted(required - normalized_members.keys())
        if missing:
            fail("backup is missing required members: " + ", ".join(missing))

        identity_member = normalized_members["etc/relayerd/identity.json"]
        release_member = normalized_members["etc/relayerd/release.json"]
        certificate_member = normalized_members["var/lib/relayerd/tls/staker.crt"]
        identity_file = archive.extractfile(identity_member)
        release_file = archive.extractfile(release_member)
        certificate_file = archive.extractfile(certificate_member)
        if identity_file is None or release_file is None or certificate_file is None:
            fail("backup identity, release metadata, or TLS certificate is unreadable")
        identity_bytes = identity_file.read()
        release_bytes = release_file.read()
        certificate_pem = certificate_file.read()
except (OSError, tarfile.TarError) as error:
    fail(f"backup archive is unreadable: {error}")

try:
    identity = json.loads(identity_bytes.decode("utf-8"))
except (UnicodeDecodeError, json.JSONDecodeError) as error:
    fail(f"archived identity metadata is invalid JSON: {error}")

try:
    release = json.loads(release_bytes.decode("utf-8"))
except (UnicodeDecodeError, json.JSONDecodeError) as error:
    fail(f"archived release metadata is invalid JSON: {error}")


def positive_integer(value):
    return isinstance(value, int) and not isinstance(value, bool) and value >= 1


schema_fields = (
    "configSchema",
    "stateSchema",
    "minimumReadableStateSchema",
    "minimumAutomaticRollbackStateSchema",
)
for field in schema_fields:
    manifest_value = manifest.get(field, 1)
    release_value = release.get(field, 1)
    if not positive_integer(manifest_value) or not positive_integer(release_value):
        fail(f"backup {field} must be a positive integer")
    if manifest_value != release_value:
        fail(f"backup manifest {field} does not match archived release metadata")
if manifest.get("version") != release.get("version"):
    fail("backup manifest version does not match archived release metadata")

node_id = identity.get("p2pNodeId")
certificate_sha = identity.get("tlsCertificateSha256")
if identity.get("schemaVersion") != 1:
    fail("archived identity metadata has an unsupported schema version")
if not isinstance(node_id, str) or not node_id.startswith("NodeID-"):
    fail("archived identity metadata has an invalid P2P NodeID")
if not isinstance(certificate_sha, str) or not re.fullmatch(r"[0-9a-f]{64}", certificate_sha):
    fail("archived identity metadata has an invalid TLS certificate SHA-256")

actual_certificate_sha = hashlib.sha256(certificate_pem).hexdigest()
if certificate_sha != actual_certificate_sha:
    fail("archived identity metadata does not match the archived TLS certificate checksum")
if manifest.get("p2pNodeId") != node_id:
    fail("backup manifest P2P NodeID does not match archived identity metadata")
if manifest.get("tlsCertificateSha256") != certificate_sha:
    fail("backup manifest TLS certificate checksum does not match archived identity metadata")

try:
    certificate_der = ssl.PEM_cert_to_DER_cert(certificate_pem.decode("ascii"))
except (UnicodeDecodeError, ValueError) as error:
    fail(f"archived TLS certificate is invalid: {error}")
derived_payload = hashlib.new("ripemd160", hashlib.sha256(certificate_der).digest()).digest()
derived_node_id = "NodeID-" + cb58_encode(derived_payload)
if derived_node_id != node_id:
    fail("archived TLS certificate does not derive the archived P2P NodeID")
PY
}


validate_restore_runtime_schema() {
  local manifest="$1" discovery="$2"
  local backup_config backup_state runtime_config runtime_state runtime_min source_label
  backup_config="$(jq -r '.configSchema // 1' "$manifest")"
  backup_state="$(jq -r '.stateSchema // 1' "$manifest")"
  if [[ "$(jq -r '.daemonInstalled' "$discovery")" == true ]]; then
    runtime_config="$(jq -r '.recordedRelease.configSchema // 1' "$discovery")"
    runtime_state="$(jq -r '.recordedRelease.stateSchema // 1' "$discovery")"
    runtime_min="$(jq -r '.recordedRelease.minimumReadableStateSchema // 1' "$discovery")"
    source_label="installed Relayer runtime"
  else
    runtime_config="$RELEASE_CONFIG_SCHEMA"
    runtime_state="$RELEASE_STATE_SCHEMA"
    runtime_min="$RELEASE_MIN_READABLE_STATE_SCHEMA"
    source_label="selected $RELAYER_VERSION release for the subsequent reapply"
  fi
  for schema_value in "$backup_config" "$backup_state" "$runtime_config" "$runtime_state" "$runtime_min"; do
    [[ "$schema_value" =~ ^[1-9][0-9]*$ ]] || {
      printf 'ERROR: restore compatibility metadata contains a non-positive or non-integer schema value.\n' >&2
      return 1
    }
  done
  if ((backup_config > runtime_config)); then
    printf 'ERROR: backup config schema %s is newer than the %s config schema %s.\n' \
      "$backup_config" "$source_label" "$runtime_config" >&2
    printf 'Select or install a Relayer release that supports config schema %s before restoring.\n' \
      "$backup_config" >&2
    return 1
  fi
  if ((backup_state < runtime_min || backup_state > runtime_state)); then
    printf 'ERROR: backup state schema %s is outside the %s readable range %s..%s.\n' \
      "$backup_state" "$source_label" "$runtime_min" "$runtime_state" >&2
    printf 'Select or install a compatible Relayer release before restoring; no VM state was changed.\n' >&2
    return 1
  fi
}


run_restore() {
  local backup="${BACKUP:-}" manifest expected actual answer vars_file backup_node_id backup_tls_sha authorize_answer
  local current_node_id="" authorization_managed=false authorization_status=0 restore_status=0 cleanup_status=0
  local observed_node_id=""
  [[ -n "$backup" ]] || die "BACKUP is required; use make relayer-restore BACKUP=/absolute/path/to/relayer-*.tar.gz"
  [[ "$backup" == /* ]] || die "BACKUP must be an absolute path to an archive created by make relayer-backup"
  [[ -f "$backup" ]] || die "BACKUP does not exist: $backup"
  [[ "$(basename "$backup")" =~ ^relayer-[0-9]{8}T[0-9]{6}\.tar\.gz$ ]] || \
    die "BACKUP filename is not a retained make relayer-backup archive"
  manifest="${backup%.tar.gz}.manifest.json"
  [[ -f "$manifest" ]] || die "matching backup manifest is missing: $manifest"

  require_command jq
  require_command python3
  expected="$(jq -r '.archive.sha256 // empty' "$manifest")"
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || die "backup manifest has no valid archive SHA-256"
  actual="$(sha256_file "$backup")"
  actual="$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')"
  expected="$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')"
  [[ "$actual" == "$expected" ]] || die "backup archive checksum does not match its manifest"
  jq -e --arg file "$(basename "$backup")" \
    '.schemaVersion == 1 and .kind == "avalanche-deploy-relayer-backup" and
     .archive.file == $file and (.p2pNodeId | startswith("NodeID-")) and
     (.tlsCertificateSha256 | test("^[0-9a-f]{64}$")) and
     ([(.configSchema // 1), (.stateSchema // 1),
       (.minimumReadableStateSchema // 1), (.minimumAutomaticRollbackStateSchema // 1)] |
       all(.[]; type == "number" and . >= 1 and floor == .))' \
    "$manifest" >/dev/null || die "backup manifest schema or archive name is invalid"
  validate_restore_archive_identity "$backup" "$manifest" || \
    die "backup identity metadata, TLS certificate, and manifest do not describe one permanent NodeID"

  run_authorization_preflight
  backup_node_id="$(jq -r '.p2pNodeId' "$manifest")"
  backup_tls_sha="$(jq -r '.tlsCertificateSha256' "$manifest")"
  if [[ "$(jq -r '.tlsIdentityExists' "$DISCOVERY_FILE")" == true ]]; then
    current_node_id="$(jq -r '.p2pNodeId' "$DISCOVERY_FILE")"
  fi
  run_preflight
  jq -e \
    --argjson network "$(jq '.networkId' "$METADATA_FILE")" \
    --arg subnet "$(jq -r '.subnetId' "$METADATA_FILE")" \
    --arg blockchain "$(jq -r '.blockchainId' "$METADATA_FILE")" \
    --argjson evm "$(jq '.evmChainId' "$METADATA_FILE")" \
    --arg chain_name "$(jq -r '.chainName' "$METADATA_FILE")" \
    --arg manager "$(jq -r '.managerAddress' "$METADATA_FILE")" \
    --arg validator_manager "$(jq -r '.validatorManagerAddress' "$METADATA_FILE")" \
    '.networkId == $network and .subnetId == $subnet and .blockchainId == $blockchain and
     .evmChainId == $evm and .chainName == $chain_name and
     (.managerAddress | ascii_downcase) == ($manager | ascii_downcase) and
     (.validatorManagerAddress | ascii_downcase) == ($validator_manager | ascii_downcase)' \
    "$manifest" >/dev/null || die "backup manifest belongs to a different Avalanche Deploy L1"

  # The restore playbook restores config and bbolt state, not a daemon binary.
  # Prove the currently installed runtime can read them; if the workload was
  # removed, prove the explicitly selected release can read them before the
  # operator later reapplies it. This runs before authorization or VM mutation.
  prepare_release false
  validate_restore_runtime_schema "$manifest" "$DISCOVERY_FILE" ||
    die "backup schemas are incompatible with the runtime that would read them"

  printf 'Restore %s to %s (%s) and retain an automatic pre-restore rollback? [y/N] ' \
    "$(basename "$backup")" "$TARGET_NAME" "$TARGET_HOST"
  IFS= read -r answer
  case "$answer" in y|Y|yes|YES|Yes) ;; *) printf 'Restore cancelled; no changes made.\n'; return 0 ;; esac

  vars_file="$WORK_DIR/restore-vars.json"
  jq -n \
    --arg archive "$backup" \
    --arg utility "$RELEASE_RESTORE" \
    --arg node_id "$backup_node_id" \
    --arg certificate_sha "$backup_tls_sha" \
    '{
      relayer_restore_archive_local: $archive,
      relayer_restore_utility_local: $utility,
      relayer_restore_expected_p2p_node_id: $node_id,
      relayer_restore_expected_tls_certificate_sha256: $certificate_sha
    }' >"$vars_file"

  if authorization_needed "$backup_node_id" "$DISCOVERY_FILE"; then
    print_protocol_authorization "$backup_node_id" "$DISCOVERY_FILE"
    printf 'Authorize this validated backup identity on the managed validators now? [y/N] '
    IFS= read -r authorize_answer
    case "$authorize_answer" in
      y | Y | yes | YES | Yes)
        authorization_managed=true
        (run_authorization true "$backup_node_id") || authorization_status=$?
        ;;
      *)
        printf 'Restore stopped. Authorize the backup NodeID manually, then rerun make relayer-restore.\n'
        return 1
        ;;
    esac
  else
    protocol_privacy_gate "$backup_node_id" "$DISCOVERY_FILE" \
      "The selected backup was not restored. Update every validator, then rerun make relayer-restore." || return 1
    peer_visibility_gate "$DISCOVERY_FILE" || return 1
  fi

  if ((authorization_status != 0)); then
    printf 'Managed backup authorization failed. Restoring the pre-restore authorization set.\n' >&2
    (run_authorization_cleanup "$current_node_id") || cleanup_status=$?
    if ((cleanup_status != 0)); then
      printf 'ERROR: temporary backup authorization cleanup also failed; inspect every validator before retrying.\n' >&2
    fi
    return "$authorization_status"
  fi

  (
    cd "$ROOT_DIR/ansible"
    ANSIBLE_CONFIG="$ROOT_DIR/ansible/ansible.cfg" \
      ansible-playbook -i "$INVENTORY_FILE" playbooks/l1/restore-relayer.yml -e "@$vars_file"
  ) || restore_status=$?
  if ((restore_status == 0)); then
    doctor_vm || restore_status=$?
  fi

  if ((restore_status == 0)); then
    # Reconcile even when the owner pre-authorized the backup manually. The
    # helper removes only obsolete NodeIDs recorded in its managed manifest.
    if [[ "$current_node_id" != "$backup_node_id" ]]; then
      (run_authorization_cleanup "$backup_node_id") || cleanup_status=$?
    fi
  elif [[ "$authorization_managed" == true ]]; then
    if observed_node_id="$(
      (run_authorization_preflight >/dev/null && \
        jq -r 'if .tlsIdentityExists then .p2pNodeId else "" end' "$DISCOVERY_FILE") 2>/dev/null
    )" && \
      [[ "$observed_node_id" == "$current_node_id" ]]; then
      (run_authorization_cleanup "$current_node_id") || cleanup_status=$?
    else
      cleanup_status=1
      printf 'ERROR: restore failed and the original permanent identity was not confirmed.\n' >&2
      printf 'The old and backup NodeIDs remain authorized to preserve recovery access.\n' >&2
    fi
  fi

  if ((cleanup_status != 0)); then
    printf 'ERROR: restore authorization cleanup is incomplete; inspect every validator before another restore.\n' >&2
    return 1
  fi
  if ((restore_status != 0)); then
    printf 'ERROR: Relayer restore failed; the original authorization set was restored.\n' >&2
    return "$restore_status"
  fi
  printf 'Relayer restore and temporary NodeID authorization cleanup are complete.\n'
}
