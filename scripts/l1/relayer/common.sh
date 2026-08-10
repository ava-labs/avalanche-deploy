# shellcheck shell=bash
# Shared operator-facing messages, command checks, and temporary workspace lifecycle.

usage() {
  cat >&2 <<'EOF'
usage: scripts/l1/relayer.sh [prereqs|doctor|prepare|authorize|install|access|status|logs|backup|restore|upgrade|remove]

All infrastructure and L1 metadata are discovered from l1.env, Terraform state,
and the matching Ansible inventory. The official stable release is selected by
default; set RELAYER_VERSION only to require an exact tag. Set PURGE=true with
remove to permanently delete retained material. Protocol-private L1s use
prepare, optional authorize, then install.
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
