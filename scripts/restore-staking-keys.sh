#!/bin/bash
# Restore staking keys from S3 to a node
#
# Usage:
#   ./restore-staking-keys.sh <source-hostname> <target-ip>
#   ./restore-staking-keys.sh validator-1 10.0.1.50           # L1 validator
#   ./restore-staking-keys.sh primary-validator-1 10.0.1.50   # Primary Network validator
#
# This downloads keys from S3 and copies them to the target node.
# The target node should have avalanchego stopped before running this.

set -e

SOURCE_HOST="${1:-}"
TARGET_IP="${2:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INVENTORY="$REPO_ROOT/ansible/inventory/aws_hosts"

if [ -z "$SOURCE_HOST" ] || [ -z "$TARGET_IP" ]; then
    echo "Usage: $0 <source-hostname> <target-ip>"
    echo ""
    echo "Arguments:"
    echo "  source-hostname  The inventory hostname to restore keys from"
    echo "  target-ip        The IP address of the target node"
    echo ""
    echo "Examples:"
    echo "  $0 validator-1 10.0.1.50           # L1 validator"
    echo "  $0 primary-validator-1 10.0.1.50   # Primary Network validator"
    echo ""
    echo "Available validators with backups:"
    echo "  L1 Validators:"
    grep -E "^validator-" "$INVENTORY" 2>/dev/null | cut -d' ' -f1 | sed 's/^/    /' || echo "    (none)"
    echo "  Primary Network Validators:"
    grep -E "^primary-validator" "$INVENTORY" 2>/dev/null | cut -d' ' -f1 | sed 's/^/    /' || echo "    (none)"
    echo ""
    echo "Prerequisites:"
    echo "  1. Keys must be backed up to S3 (run: make backup-keys)"
    echo "  2. Target node should have avalanchego stopped"
    exit 1
fi

# Get bucket name from Terraform
cd "$REPO_ROOT/terraform/aws"
BUCKET=$(terraform output -raw staking_keys_bucket 2>/dev/null || echo "")
KMS_ARN=$(terraform output -raw staking_keys_kms_key_arn 2>/dev/null || echo "")

if [ -z "$BUCKET" ]; then
    echo "Error: Could not get staking_keys_bucket from Terraform"
    echo "Ensure Terraform has been applied with primary_validator_count > 0"
    exit 1
fi

echo "=== Restoring Staking Keys ==="
echo "Source: s3://$BUCKET/$SOURCE_HOST/staking-keys.tar.gz"
echo "Target: $TARGET_IP"
echo ""

# Download keys locally
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

echo "Downloading keys from S3..."
aws s3 cp "s3://$BUCKET/$SOURCE_HOST/staking-keys.tar.gz" "$TEMP_DIR/staking-keys.tar.gz"

if [ ! -f "$TEMP_DIR/staking-keys.tar.gz" ]; then
    echo "Error: Failed to download keys from S3"
    exit 1
fi

# Get SSH key from inventory
SSH_KEY=$(grep "ansible_ssh_private_key_file" "$REPO_ROOT/ansible/inventory/aws_hosts" | head -1 | sed 's/.*=//')
SSH_OPTS="-o StrictHostKeyChecking=no"

if [ -n "$SSH_KEY" ] && [ -f "$SSH_KEY" ]; then
    SSH_OPTS="$SSH_OPTS -i $SSH_KEY"
fi

echo "Stopping avalanchego on target..."
ssh $SSH_OPTS ubuntu@"$TARGET_IP" "sudo systemctl stop avalanchego || true"

echo "Clearing existing staking keys..."
ssh $SSH_OPTS ubuntu@"$TARGET_IP" "sudo rm -rf /var/lib/avalanchego/staking/*"

echo "Copying keys to target..."
scp $SSH_OPTS "$TEMP_DIR/staking-keys.tar.gz" ubuntu@"$TARGET_IP":/tmp/

echo "Extracting keys..."
ssh $SSH_OPTS ubuntu@"$TARGET_IP" "
    sudo tar -xzf /tmp/staking-keys.tar.gz -C /var/lib/avalanchego/staking/
    sudo chown -R avalanche:avalanche /var/lib/avalanchego/staking/
    sudo chmod 700 /var/lib/avalanchego/staking/
    sudo chmod 600 /var/lib/avalanchego/staking/*
    rm /tmp/staking-keys.tar.gz
"

echo ""
echo "=== Keys Restored ==="
echo ""
echo "Start avalanchego on target:"
echo "  ssh ubuntu@$TARGET_IP 'sudo systemctl start avalanchego'"
echo ""
echo "Verify Node ID:"
echo "  curl http://$TARGET_IP:9650/ext/info -X POST -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"info.getNodeID\"}'"
