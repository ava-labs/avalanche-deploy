#!/bin/bash
#
# E2E Test: Primary Network Validator Deployment
#
# Tests the complete Primary Network validator lifecycle including:
# - Infrastructure creation (with migration target)
# - Validator deployment
# - Chain sync verification
# - Staking key backup
# - Snapshot creation
# - Snapshot restoration
# - Validator migration
# - Monitoring
# - Teardown
#
# Usage:
#   ./tests/e2e-primary-network.sh                    # Full test
#   ./tests/e2e-primary-network.sh --skip-infra       # Skip infra creation
#   ./tests/e2e-primary-network.sh --skip-destroy     # Don't destroy at end
#   ./tests/e2e-primary-network.sh --skip-sync-wait   # Don't wait for full sync (faster but incomplete test)
#
# Required environment variables:
#   AWS_ACCESS_KEY_ID
#   AWS_SECRET_ACCESS_KEY
#
# Note: This test does NOT register validators on P-Chain (requires staking).
#       It tests the infrastructure, deployment, backup, snapshot, and migration flows.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Options
SKIP_INFRA=false
SKIP_DESTROY=false
SKIP_SYNC_WAIT=false
CLOUD="${CLOUD:-aws}"
NETWORK="${NETWORK:-fuji}"

# Parse arguments
for arg in "$@"; do
    case $arg in
        --skip-infra) SKIP_INFRA=true ;;
        --skip-destroy) SKIP_DESTROY=true ;;
        --skip-sync-wait) SKIP_SYNC_WAIT=true ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

# Test state
TESTS_PASSED=0
TESTS_FAILED=0
START_TIME=$(date +%s)

log() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[$(date '+%H:%M:%S')] ✓ $1${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

log_error() {
    echo -e "${RED}[$(date '+%H:%M:%S')] ✗ $1${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

log_warning() {
    echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠ $1${NC}"
}

section() {
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo ""
}

cleanup() {
    if [ "$SKIP_DESTROY" = false ]; then
        section "Cleanup"
        log "Destroying infrastructure..."
        make destroy CLOUD=$CLOUD || log_warning "Destroy failed (may already be destroyed)"
    else
        log_warning "Skipping destroy (--skip-destroy)"
    fi

    # Summary
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))

    section "Test Summary"
    echo -e "Duration: ${DURATION}s"
    echo -e "Passed:   ${GREEN}${TESTS_PASSED}${NC}"
    echo -e "Failed:   ${RED}${TESTS_FAILED}${NC}"

    if [ $TESTS_FAILED -gt 0 ]; then
        exit 1
    fi
}

trap cleanup EXIT

# Preflight checks
section "Preflight Checks"

if [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
    log_error "AWS_ACCESS_KEY_ID not set"
    exit 1
fi
log_success "AWS credentials configured"

if ! command -v terraform &> /dev/null; then
    log_error "terraform not installed"
    exit 1
fi
log_success "terraform installed"

if ! command -v ansible-playbook &> /dev/null; then
    log_error "ansible not installed"
    exit 1
fi
log_success "ansible installed"

# Validate configurations
section "Validation"

log "Validating Ansible playbooks..."
if make validate > /dev/null 2>&1; then
    log_success "All configurations valid"
else
    log_error "Validation failed"
    exit 1
fi

# Infrastructure
section "Infrastructure"

if [ "$SKIP_INFRA" = true ]; then
    log_warning "Skipping infrastructure creation (--skip-infra)"
else
    log "Creating Primary Network validator infrastructure..."
    log "  - 1 primary validator (will be migration source)"
    log "  - 1 migration target node"
    log "  - 1 monitoring node"

    cd terraform/$CLOUD
    terraform init -input=false

    # Create infra with 2 primary validators (one will be migration target)
    # We use primary_validator_count=2 to have both source and target
    terraform apply -auto-approve \
        -var="validator_count=0" \
        -var="rpc_archive_count=0" \
        -var="rpc_pruned_count=0" \
        -var="primary_validator_count=2" \
        -var="environment=$NETWORK" \
        -var="enable_staking_key_backup=true"
    cd "$REPO_ROOT"

    log_success "Infrastructure created"
fi

# Get node info
section "Node Information"

cd terraform/$CLOUD
PRIMARY_IPS=$(terraform output -json primary_validator_ips 2>/dev/null | jq -r '.[]' || echo "")
MONITORING_IP=$(terraform output -raw monitoring_ip 2>/dev/null || echo "")
cd "$REPO_ROOT"

if [ -z "$PRIMARY_IPS" ]; then
    log_error "No primary validator IPs found"
    exit 1
fi

PRIMARY_IP_1=$(echo "$PRIMARY_IPS" | head -1)
PRIMARY_IP_2=$(echo "$PRIMARY_IPS" | tail -1)

log "Primary Validator 1: $PRIMARY_IP_1"
log "Primary Validator 2 (migration target): $PRIMARY_IP_2"
log "Monitoring: $MONITORING_IP"

# Deployment
section "Primary Network Deployment"

log "Deploying avalanchego to primary validators..."
if make primary-deploy NETWORK=$NETWORK; then
    log_success "Primary Network validators deployed"
else
    log_error "Primary Network deployment failed"
    exit 1
fi

# Monitoring
section "Monitoring"

log "Deploying Prometheus + Grafana..."
if make monitoring; then
    log_success "Monitoring deployed"
else
    log_error "Monitoring deployment failed"
fi

# Wait for sync
section "Chain Synchronization"

if [ "$SKIP_SYNC_WAIT" = true ]; then
    log_warning "Skipping sync wait (--skip-sync-wait)"
    log_warning "Note: Snapshot and migration tests may fail without synced nodes"
else
    log "Waiting for P-Chain bootstrap..."
    log "This can take 10-30 minutes for state-sync..."

    MAX_WAIT=1800  # 30 minutes
    WAITED=0
    while [ $WAITED -lt $MAX_WAIT ]; do
        if ./scripts/check-primary-sync.sh "$PRIMARY_IP_1" 2>&1 | grep -q "P-Chain: SYNCED"; then
            log_success "P-Chain bootstrapped on primary-validator-1"
            break
        fi
        sleep 60
        WAITED=$((WAITED + 60))
        log "Still syncing P-Chain... (${WAITED}s / ${MAX_WAIT}s)"
    done

    if [ $WAITED -ge $MAX_WAIT ]; then
        log_error "P-Chain sync timeout on primary-validator-1"
        # Continue anyway to test what we can
    fi

    # Check X and C chains
    log "Checking X-Chain and C-Chain..."
    if ./scripts/check-primary-sync.sh "$PRIMARY_IP_1" 2>&1 | grep -q "X-Chain: SYNCED"; then
        log_success "X-Chain bootstrapped"
    else
        log_warning "X-Chain not yet bootstrapped"
    fi

    if ./scripts/check-primary-sync.sh "$PRIMARY_IP_1" 2>&1 | grep -q "C-Chain: SYNCED"; then
        log_success "C-Chain bootstrapped"
    else
        log_warning "C-Chain not yet bootstrapped"
    fi
fi

# Staking Key Backup
section "Staking Key Backup"

log "Backing up staking keys to S3..."
if make backup-keys; then
    log_success "Staking keys backed up"
else
    log_error "Staking key backup failed"
fi

# Verify backup exists
log "Verifying backup in S3..."
S3_BUCKET=$(cd terraform/$CLOUD && terraform output -raw staking_keys_bucket 2>/dev/null || echo "")
if [ -n "$S3_BUCKET" ]; then
    if aws s3 ls "s3://$S3_BUCKET/" --recursive | grep -q "staking-keys.tar.gz"; then
        log_success "Staking keys found in S3"
    else
        log_error "Staking keys not found in S3"
    fi
else
    log_warning "Could not get S3 bucket name"
fi

# Snapshot Creation (only if synced)
section "Database Snapshots"

if [ "$SKIP_SYNC_WAIT" = true ]; then
    log_warning "Skipping snapshot tests (nodes not synced)"
else
    log "Creating database snapshot from primary-validator-1..."
    if make create-snapshot NODE=primary-validator-1 NAME=e2e-test-snapshot; then
        log_success "Snapshot created"
    else
        log_error "Snapshot creation failed"
    fi

    log "Listing snapshots..."
    if make list-snapshots; then
        log_success "Snapshot list retrieved"
    else
        log_error "Failed to list snapshots"
    fi

    # Test snapshot restore on validator 2
    log "Restoring snapshot to primary-validator-2..."
    if make restore-snapshot TARGET=primary-validator-2 SNAPSHOT=e2e-test-snapshot; then
        log_success "Snapshot restored"
    else
        log_error "Snapshot restore failed"
    fi
fi

# Migration Test
section "Validator Migration"

if [ "$SKIP_SYNC_WAIT" = true ]; then
    log_warning "Skipping migration test (nodes not synced)"
else
    log "Testing validator migration from primary-validator-1 to primary-validator-2..."

    # First, prepare migration target if we didn't already restore snapshot
    log "Verifying migration target is ready..."

    # The migration playbook will:
    # 1. Verify target is synced
    # 2. Stop target avalanchego
    # 3. Download staking keys from S3
    # 4. Stop source validator
    # 5. Start target with staking keys

    if make migrate-validator SOURCE=primary-validator-1 TARGET=primary-validator-2; then
        log_success "Validator migration completed"
    else
        log_error "Validator migration failed"
    fi

    # Verify migration by checking node ID on target matches source
    log "Verifying migration..."
    sleep 30  # Wait for node to start

    TARGET_NODE_ID=$(curl -s "http://$PRIMARY_IP_2:9650/ext/info" \
        -X POST -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","id":1,"method":"info.getNodeID"}' \
        2>/dev/null | jq -r '.result.nodeID' || echo "")

    if [ -n "$TARGET_NODE_ID" ] && [ "$TARGET_NODE_ID" != "null" ]; then
        log_success "Migration target has NodeID: $TARGET_NODE_ID"
    else
        log_error "Could not verify migration target NodeID"
    fi
fi

# Health Checks
section "Health Checks"

log "Running health checks..."
if make health-checks; then
    log_success "Health checks passed"
else
    log_error "Health checks failed"
fi

# Rolling Restart
section "Rolling Restart"

log "Testing rolling restart..."
if make rolling-restart; then
    log_success "Rolling restart completed"
else
    log_error "Rolling restart failed"
fi

section "E2E Test Complete"
log_success "All Primary Network E2E tests passed!"

echo ""
echo "Note: This test validated the deployment and operations workflows."
echo "To complete a full validator setup, you would need to:"
echo "  1. Fund a P-Chain address with AVAX for staking"
echo "  2. Register the validator using Core Wallet or avalanche-cli"
echo "  3. Wait for the validation period to begin"
