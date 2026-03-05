#!/bin/bash
# Create a database snapshot from a synced Primary Network validator
#
# Usage:
#   ./create-snapshot.sh <validator-hostname>
#   ./create-snapshot.sh primary-validator-1
#   ./create-snapshot.sh primary-validator-1 my-custom-name
#
# The snapshot is uploaded to S3 and can be used for:
#   - Faster migration (instead of state-sync)
#   - Disaster recovery
#   - Spinning up new nodes quickly

set -euo pipefail

HOSTNAME="${1:-}"
SNAPSHOT_NAME="${2:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLOUD="${CLOUD:-aws}"
INVENTORY="$REPO_ROOT/ansible/inventory/${CLOUD}_hosts"

if [ "$CLOUD" != "aws" ]; then
    echo "Error: snapshot creation is currently supported only for CLOUD=aws."
    exit 1
fi

if [ -z "$HOSTNAME" ]; then
    echo "Usage: $0 <validator-hostname> [snapshot-name]"
    echo ""
    echo "Arguments:"
    echo "  validator-hostname  The synced node to create snapshot from"
    echo "  snapshot-name       Optional custom name (default: hostname-date)"
    echo ""
    echo "Examples:"
    echo "  $0 primary-validator-1"
    echo "  $0 primary-validator-1 mainnet-2025-02"
    echo ""
    echo "Available validators:"
    grep -E "^primary-validator|^validator-" "$INVENTORY" 2>/dev/null | cut -d' ' -f1 | sed 's/^/  /' || echo "  (none found)"
    echo ""
    echo "Note: The node must be fully synced (all chains bootstrapped)"
    exit 1
fi

cd "$REPO_ROOT/ansible"

if [ -n "$SNAPSHOT_NAME" ]; then
    echo "Creating snapshot '$SNAPSHOT_NAME' from $HOSTNAME..."
    ansible-playbook -i "$INVENTORY" playbooks/primary-network/create-snapshot.yml --limit "$HOSTNAME" -e "snapshot_name=$SNAPSHOT_NAME"
else
    echo "Creating snapshot from $HOSTNAME..."
    ansible-playbook -i "$INVENTORY" playbooks/primary-network/create-snapshot.yml --limit "$HOSTNAME"
fi

echo ""
echo "List all snapshots:"
echo "  aws s3 ls s3://\$(terraform -chdir=../terraform/primary-network/$CLOUD output -raw staking_keys_bucket)/snapshots/"
