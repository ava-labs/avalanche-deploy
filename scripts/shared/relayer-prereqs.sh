#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODE="${1:-}"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/relayer-prereqs.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT INT TERM

usage() {
    echo "usage: scripts/shared/relayer-prereqs.sh vm" >&2
    exit 2
}

[[ "$MODE" == "vm" ]] || usage

run_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        echo "ERROR: root privileges are required; rerun with sudo available or install the listed packages as root" >&2
        exit 1
    fi
}

install_macos() {
    command -v brew >/dev/null 2>&1 || {
        echo "ERROR: Homebrew is required on macOS; install it from https://brew.sh and rerun" >&2
        exit 1
    }
    local packages=(curl jq python openssh terraform ansible)
    brew install "${packages[@]}"
}

apt_has_repo() {
    grep -Rqs "$1" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null
}

install_apt() {
    local codename
    run_root apt-get update
    run_root apt-get install -y ca-certificates curl gnupg jq python3 openssh-client
    if ! command -v terraform >/dev/null 2>&1; then
        curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor >"$TEMP_DIR/hashicorp-archive-keyring.gpg"
        run_root install -m 0644 "$TEMP_DIR/hashicorp-archive-keyring.gpg" /usr/share/keyrings/hashicorp-archive-keyring.gpg
        if ! apt_has_repo apt.releases.hashicorp.com; then
            codename="$(awk -F= '$1 == "VERSION_CODENAME" {gsub(/"/, "", $2); print $2; exit}' /etc/os-release)"
            [[ -n "$codename" ]] || {
                echo "ERROR: VERSION_CODENAME is missing from /etc/os-release; install Terraform manually from https://developer.hashicorp.com/terraform/install" >&2
                exit 1
            }
            printf 'deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com %s main\n' \
                "$codename" >"$TEMP_DIR/hashicorp.list"
            run_root install -m 0644 "$TEMP_DIR/hashicorp.list" /etc/apt/sources.list.d/hashicorp.list
        fi
        run_root apt-get update
    fi
    run_root apt-get install -y terraform ansible
}

install_dnf() {
    run_root dnf install -y ca-certificates curl jq python3 openssh-clients dnf-plugins-core
    if ! command -v terraform >/dev/null 2>&1; then
        run_root dnf config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
    fi
    run_root dnf install -y terraform ansible-core
}

case "$(uname -s)" in
    Darwin) install_macos ;;
    Linux)
        if command -v apt-get >/dev/null 2>&1; then
            install_apt
        elif command -v dnf >/dev/null 2>&1; then
            install_dnf
        else
            echo "ERROR: unsupported Linux package manager; install curl, jq, python3, OpenSSH, Terraform, and Ansible, then rerun" >&2
            exit 1
        fi
        ;;
    *)
        echo "ERROR: unsupported platform $(uname -s); use macOS/Homebrew or Linux with apt-get/dnf" >&2
        exit 1
        ;;
esac

ansible-galaxy collection install -r "$ROOT_DIR/ansible/requirements.yml"

echo "Relayer VM operator prerequisites are installed. Cloud credentials, SSH access, and networking were not changed."
