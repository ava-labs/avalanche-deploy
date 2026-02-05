#!/bin/bash
# Restore a database snapshot to a node
#
# Usage:
#   ./restore-snapshot.sh <target-hostname>
#   ./restore-snapshot.sh migration-target
#   ./restore-snapshot.sh migration-target my-custom-snapshot
#
# This restores the 'latest' snapshot by default, or a specific named snapshot.

set -e

TARGET="${1:-}"
SNAPSHOT_NAME="${2:-latest}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INVENTORY="$REPO_ROOT/ansible/inventory/aws_hosts"

if [ -z "$TARGET" ]; then
    echo "Usage: $0 <target-hostname> [snapshot-name]"
    echo ""
    echo "Arguments:"
    echo "  target-hostname  The node to restore snapshot to"
    echo "  snapshot-name    Snapshot to restore (default: latest)"
    echo ""
    echo "Examples:"
    echo "  $0 migration-target              # Restore 'latest' snapshot"
    echo "  $0 migration-target mainnet-2025-02  # Restore specific snapshot"
    echo ""
    echo "Available nodes:"
    grep -E "^primary-validator|^validator-|^migration" "$INVENTORY" 2>/dev/null | cut -d' ' -f1 | sed 's/^/  /' || echo "  (none found)"
    echo ""
    echo "List available snapshots:"
    echo "  aws s3 ls s3://\$(terraform -chdir=terraform/aws output -raw staking_keys_bucket)/snapshots/"
    exit 1
fi

echo "Restoring snapshot '$SNAPSHOT_NAME' to $TARGET..."
cd "$REPO_ROOT/ansible"

ansible-playbook playbooks/15-restore-snapshot.yml --limit "$TARGET" -e "snapshot_name=$SNAPSHOT_NAME"
