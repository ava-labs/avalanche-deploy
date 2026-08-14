#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODE="${1:-}"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/relayer-prereqs.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT INT TERM

usage() {
    echo "usage: scripts/shared/relayer-prereqs.sh <vm|k8s>" >&2
    exit 2
}

[[ "$MODE" == "vm" || "$MODE" == "k8s" ]] || usage

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
    local packages=(curl jq python openssh)
    if [[ "$MODE" == "vm" ]]; then
        packages+=(terraform ansible)
    else
        packages+=(kubectl helm)
    fi
    brew install "${packages[@]}"
}

apt_has_repo() {
    grep -Rqs "$1" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null
}

install_apt() {
    local codename
    run_root apt-get update
    run_root apt-get install -y ca-certificates curl gnupg jq python3 openssh-client
    if [[ "$MODE" == "vm" ]]; then
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
        return
    fi

    if ! command -v kubectl >/dev/null 2>&1; then
        local stable minor
        stable="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
        minor="$(sed -E 's/^(v[0-9]+\.[0-9]+).*/\1/' <<<"$stable")"
        curl -fsSL "https://pkgs.k8s.io/core:/stable:/${minor}/deb/Release.key" | gpg --dearmor >"$TEMP_DIR/kubernetes-apt-keyring.gpg"
        run_root install -d -m 0755 /etc/apt/keyrings
        run_root install -m 0644 "$TEMP_DIR/kubernetes-apt-keyring.gpg" /etc/apt/keyrings/kubernetes-apt-keyring.gpg
        printf 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/%s/deb/ /\n' "$minor" >"$TEMP_DIR/kubernetes.list"
        run_root install -m 0644 "$TEMP_DIR/kubernetes.list" /etc/apt/sources.list.d/kubernetes.list
        run_root apt-get update
        run_root apt-get install -y kubectl
    fi
    if ! command -v helm >/dev/null 2>&1; then
        curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o "$TEMP_DIR/get-helm-3"
        chmod 0700 "$TEMP_DIR/get-helm-3"
        run_root "$TEMP_DIR/get-helm-3"
    fi
}

install_dnf() {
    run_root dnf install -y ca-certificates curl jq python3 openssh-clients dnf-plugins-core
    if [[ "$MODE" == "vm" ]]; then
        if ! command -v terraform >/dev/null 2>&1; then
            run_root dnf config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
        fi
        run_root dnf install -y terraform ansible-core
        return
    fi

    if ! command -v kubectl >/dev/null 2>&1; then
        local stable minor
        stable="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
        minor="$(sed -E 's/^(v[0-9]+\.[0-9]+).*/\1/' <<<"$stable")"
        cat >"$TEMP_DIR/kubernetes.repo" <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/${minor}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${minor}/rpm/repodata/repomd.xml.key
EOF
        run_root install -m 0644 "$TEMP_DIR/kubernetes.repo" /etc/yum.repos.d/kubernetes.repo
        run_root dnf install -y kubectl
    fi
    if ! command -v helm >/dev/null 2>&1; then
        curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o "$TEMP_DIR/get-helm-3"
        chmod 0700 "$TEMP_DIR/get-helm-3"
        run_root "$TEMP_DIR/get-helm-3"
    fi
}

case "$(uname -s)" in
    Darwin) install_macos ;;
    Linux)
        if command -v apt-get >/dev/null 2>&1; then
            install_apt
        elif command -v dnf >/dev/null 2>&1; then
            install_dnf
        else
            echo "ERROR: unsupported Linux package manager; install curl, jq, python3, OpenSSH, and $([[ "$MODE" == vm ]] && echo 'Terraform plus Ansible' || echo 'kubectl plus Helm'), then rerun" >&2
            exit 1
        fi
        ;;
    *)
        echo "ERROR: unsupported platform $(uname -s); use macOS/Homebrew or Linux with apt-get/dnf" >&2
        exit 1
        ;;
esac

if [[ "$MODE" == "vm" ]]; then
    ansible-galaxy collection install -r "$ROOT_DIR/ansible/requirements.yml"
fi

echo "Relayer $MODE operator prerequisites are installed. Cloud credentials, SSH access, Kubernetes RBAC, StorageClasses, and networking were not changed."
