#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/shared/relayer-doctor-lib.sh
source "$ROOT_DIR/scripts/shared/relayer-doctor-lib.sh"

ACTION="${1:-install}"
OFFICIAL_RELAYER_REPOSITORY="ava-labs/avalanche-vmc-relayer"
DEFAULT_RELAYER_VERSION_SELECTOR="official-latest"
RELAYER_VERSION="${RELAYER_VERSION:-$DEFAULT_RELAYER_VERSION_SELECTOR}"
RELAYER_PRERELEASE_FALLBACK="${RELAYER_PRERELEASE_FALLBACK:-v0.1.0-rc.8}"
L1_ENV="$ROOT_DIR/l1.env"
RELAYER_REPOSITORY="${RELAYER_DEVELOPMENT_REPOSITORY:-$OFFICIAL_RELAYER_REPOSITORY}"
RELAYER_DEVELOPMENT_TOKEN="${RELAYER_DEVELOPMENT_TOKEN:-}"

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
RELEASE_RESTORE=""
CONSOLE_IMAGE=""
INFO_RPC_URL=""

# shellcheck source=scripts/l1/relayer/common.sh
source "$ROOT_DIR/scripts/l1/relayer/common.sh"
# shellcheck source=scripts/l1/relayer/state.sh
source "$ROOT_DIR/scripts/l1/relayer/state.sh"
# shellcheck source=scripts/l1/relayer/prerequisites.sh
source "$ROOT_DIR/scripts/l1/relayer/prerequisites.sh"
# shellcheck source=scripts/l1/relayer/doctor.sh
source "$ROOT_DIR/scripts/l1/relayer/doctor.sh"
# shellcheck source=scripts/l1/relayer/management.sh
source "$ROOT_DIR/scripts/l1/relayer/management.sh"
# shellcheck source=scripts/l1/relayer/authorization.sh
source "$ROOT_DIR/scripts/l1/relayer/authorization.sh"
# shellcheck source=scripts/l1/relayer/installation.sh
source "$ROOT_DIR/scripts/l1/relayer/installation.sh"

main() {
  [[ $# -le 1 ]] || usage
  validate_release_source
  if [[ "$ACTION" =~ ^(doctor|prepare|install|restore|upgrade)$ ]]; then
    resolve_release_version
    if [[ ! "$RELAYER_VERSION" =~ ^v[0-9A-Za-z][0-9A-Za-z.+-]*$ ]]; then
      printf 'ERROR: RELAYER_VERSION must be official-latest or a release tag such as v0.1.0\n' >&2
      usage
    fi
  fi
  case "$ACTION" in
    prereqs)
      run_prerequisites
      ;;
    doctor)
      doctor_vm
      ;;
    prepare)
      run_prepare
      ;;
    authorize)
      run_authorization
      ;;
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
      load_l1_metadata
      run_manage_playbook backup
      ;;
    restore)
      run_restore
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
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
