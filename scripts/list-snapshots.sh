#!/bin/bash
# List available database snapshots in S3
#
# Usage:
#   ./list-snapshots.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Get bucket name from Terraform
cd "$REPO_ROOT/terraform/aws"
BUCKET=$(terraform output -raw staking_keys_bucket 2>/dev/null || echo "")

if [ -z "$BUCKET" ]; then
    echo "Error: Could not get staking_keys_bucket from Terraform"
    echo "Ensure Terraform has been applied with enable_staking_key_backup=true"
    exit 1
fi

echo "=== Available Snapshots ==="
echo "Bucket: s3://$BUCKET/snapshots/"
echo ""

# List snapshots
aws s3 ls "s3://$BUCKET/snapshots/" 2>/dev/null | grep -E "\.tar\.lz4$" | while read -r line; do
    size=$(echo "$line" | awk '{print $3}')
    name=$(echo "$line" | awk '{print $4}')
    size_gb=$(echo "scale=2; $size / 1073741824" | bc 2>/dev/null || echo "?")
    echo "  $name (${size_gb}GB)"
done

echo ""

# Show latest info if available
LATEST_META=$(aws s3 cp "s3://$BUCKET/snapshots/latest.json" - 2>/dev/null || echo "")
if [ -n "$LATEST_META" ]; then
    echo "=== Latest Snapshot ==="
    echo "$LATEST_META" | jq -r '"  Name: \(.name)\n  Created: \(.created)\n  Source: \(.source_host)\n  Network: \(.network)"' 2>/dev/null || echo "  (metadata unavailable)"
fi

echo ""
echo "To restore a snapshot:"
echo "  make restore-snapshot TARGET=<node> SNAPSHOT=<name>"
echo "  ./scripts/restore-snapshot.sh <node> <snapshot-name>"
