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
    cd "$ROOT_DIR/ansible"
    ANSIBLE_CONFIG="$ROOT_DIR/ansible/ansible.cfg" \
      ansible-playbook -i "$INVENTORY_FILE" playbooks/l1/manage-relayer.yml -e "@$vars_file"
  ) || playbook_status=$?
  if [[ "$action" == backup ]]; then
    find "$backup_dir" -type f \( -name '*.tar.gz' -o -name '*.manifest.json' \) -exec chmod 0600 {} +
  fi
  return "$playbook_status"
}


run_restore() {
  local backup="${BACKUP:-}" manifest expected actual answer vars_file
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
    '.schemaVersion == 1 and .kind == "avalanche-deploy-relayer-backup" and .archive.file == $file' \
    "$manifest" >/dev/null || die "backup manifest schema or archive name is invalid"
  python3 - "$backup" <<'PY'
import pathlib
import sys
import tarfile

with tarfile.open(sys.argv[1], "r:gz") as archive:
    members = archive.getmembers()
for member in members:
    name = member.name
    path = pathlib.PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts:
        raise SystemExit(f"unsafe archive member: {name}")
    if not (member.isfile() or member.isdir()):
        raise SystemExit(f"unsupported link or special archive member: {name}")
required = {
    "etc/relayerd/config.json",
    "etc/relayerd/funding.json",
    "etc/relayerd/secrets/keystore-password",
    "etc/relayerd/secrets/console-session-secret",
    "etc/relayerd/secrets/console.env",
    "var/lib/relayerd/keystore.json",
    "var/lib/relayerd/relayer.db",
    "var/lib/relayerd/tls/staker.crt",
    "var/lib/relayerd/tls/staker.key",
}
normalized = {member.name.removeprefix("./") for member in members}
missing = sorted(required - normalized)
if missing:
    raise SystemExit("backup is missing required members: " + ", ".join(missing))
PY

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

  printf 'Restore %s to %s (%s) and retain an automatic pre-restore rollback? [y/N] ' \
    "$(basename "$backup")" "$TARGET_NAME" "$TARGET_HOST"
  IFS= read -r answer
  case "$answer" in y|Y|yes|YES|Yes) ;; *) printf 'Restore cancelled; no changes made.\n'; return 0 ;; esac

  prepare_release false
  vars_file="$WORK_DIR/restore-vars.json"
  jq -n --arg archive "$backup" --arg utility "$RELEASE_RESTORE" \
    '{relayer_restore_archive_local: $archive, relayer_restore_utility_local: $utility}' >"$vars_file"
  (
    cd "$ROOT_DIR/ansible"
    ANSIBLE_CONFIG="$ROOT_DIR/ansible/ansible.cfg" \
      ansible-playbook -i "$INVENTORY_FILE" playbooks/l1/restore-relayer.yml -e "@$vars_file"
  )
  doctor_vm
}
