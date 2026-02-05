#!/bin/bash
# Backup staking keys from a validator to S3
#
# Usage:
#   ./backup-staking-keys.sh [validator-hostname]
#   ./backup-staking-keys.sh                      # Backup all validators
#   ./backup-staking-keys.sh validator-1          # Backup specific L1 validator
#   ./backup-staking-keys.sh primary-validator-1  # Backup specific Primary Network validator
#
# This is a wrapper around the Ansible playbook for quick CLI access.

set -e

HOSTNAME="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INVENTORY="$REPO_ROOT/ansible/inventory/aws_hosts"

if [ -z "$HOSTNAME" ]; then
    echo "Backing up staking keys for ALL validators..."
    echo ""

    # Show what will be backed up
    echo "L1 Validators:"
    grep -E "^validator-" "$INVENTORY" 2>/dev/null | cut -d' ' -f1 | sed 's/^/  /' || echo "  (none)"
    echo ""
    echo "Primary Network Validators:"
    grep -E "^primary-validator" "$INVENTORY" 2>/dev/null | cut -d' ' -f1 | sed 's/^/  /' || echo "  (none)"
    echo ""

    cd "$REPO_ROOT/ansible"
    ansible-playbook playbooks/11-backup-staking-keys.yml
else
    echo "Backing up staking keys for $HOSTNAME..."
    cd "$REPO_ROOT/ansible"
    ansible-playbook playbooks/11-backup-staking-keys.yml --limit "$HOSTNAME"
fi

echo ""
echo "Backup complete! List backups with:"
echo "  aws s3 ls s3://\$(terraform -chdir=../terraform/aws output -raw staking_keys_bucket)/"
