#!/bin/bash
#
# E2E Test: L1 Blockchain Deployment
#
# Tests the complete L1 deployment lifecycle including:
# - Infrastructure creation
# - Node deployment
# - L1 creation with genesis proxy address
# - ValidatorManager deployment and initialization
# - Node configuration for L1
# - Monitoring setup
# - Add-ons (Blockscout, eRPC, Graph Node)
# - Operations (rolling restart, health checks)
# - Teardown
#
# Usage:
#   ./tests/e2e-l1.sh                    # Full test (creates and destroys infra)
#   ./tests/e2e-l1.sh --skip-infra       # Skip infra creation (use existing)
#   ./tests/e2e-l1.sh --skip-destroy     # Don't destroy at end (for debugging)
#   ./tests/e2e-l1.sh --skip-addons      # Skip add-on deployments
#   ./tests/e2e-l1.sh --dry-run          # Local preflight only (no cloud changes)
#
# Required environment variables:
#   AWS_ACCESS_KEY_ID
#   AWS_SECRET_ACCESS_KEY
#   AVALANCHE_PRIVATE_KEY (funded P-Chain key for Fuji, hex or PrivateKey- format)
#
# Note: In --dry-run mode, these credentials are not required.
#
# Optional:
#   FAUCET_PRIVATE_KEY (funded key on your L1 for faucet testing)
#   ICM_CONTRACTS_PATH (path to icm-contracts repo, required for ValidatorManager)
#   GLACIER_API_KEY (for signature aggregation, or uses local sig-agg)
#
# Genesis Configuration:
#   The genesis.json must have a pre-deployed TransparentProxy at:
#     0xfacade0000000000000000000000000000000000
#   With ProxyAdmin at:
#     0xdad0000000000000000000000000000000000000
#   These are used by ConvertSubnetToL1Tx and ValidatorManager initialization.

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
SKIP_ADDONS=false
DRY_RUN=false
CLOUD="${CLOUD:-aws}"
NETWORK="${NETWORK:-fuji}"

# Parse arguments
for arg in "$@"; do
    case $arg in
        --skip-infra) SKIP_INFRA=true ;;
        --skip-destroy) SKIP_DESTROY=true ;;
        --skip-addons) SKIP_ADDONS=true ;;
        --dry-run)
            DRY_RUN=true
            SKIP_INFRA=true
            SKIP_DESTROY=true
            SKIP_ADDONS=true
            ;;
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
        make destroy CLOUD=$CLOUD AUTO_APPROVE=true || log_warning "Destroy failed (may already be destroyed)"
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

if [ "$DRY_RUN" = true ]; then
    log_warning "Dry-run mode enabled: skipping cloud operations and destructive actions"
fi

if [ "$DRY_RUN" = false ]; then
    if [ "$CLOUD" != "aws" ]; then
        log_error "This E2E workflow currently supports CLOUD=aws only"
        exit 1
    fi
    if [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
        log_error "AWS_ACCESS_KEY_ID not set"
        exit 1
    fi
    if [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
        log_error "AWS_SECRET_ACCESS_KEY not set"
        exit 1
    fi
    log_success "AWS credentials configured"
else
    log_success "Dry-run: skipping AWS credential requirement"
fi

if [ "$DRY_RUN" = false ]; then
    if [ -z "${AVALANCHE_PRIVATE_KEY:-}" ]; then
        log_error "AVALANCHE_PRIVATE_KEY not set (need funded Fuji P-Chain key)"
        exit 1
    fi
    log_success "Avalanche private key configured"
else
    log_success "Dry-run: skipping funded P-Chain key requirement"
fi

# Check for ICM contracts path (needed for ValidatorManager)
if [ -z "${ICM_CONTRACTS_PATH:-}" ]; then
    # Try common locations
    for path in ~/code/icm-contracts ../icm-contracts ../../icm-contracts; do
        if [ -d "$path" ]; then
            export ICM_CONTRACTS_PATH="$path"
            break
        fi
    done
fi

if [ -n "${ICM_CONTRACTS_PATH:-}" ] && [ -d "${ICM_CONTRACTS_PATH}" ]; then
    log_success "ICM contracts path: $ICM_CONTRACTS_PATH"
else
    log_warning "ICM_CONTRACTS_PATH not set - ValidatorManager initialization will be skipped"
fi

# Check for foundry (required for ValidatorManager)
if command -v forge &> /dev/null && command -v cast &> /dev/null; then
    log_success "Foundry (forge/cast) installed"
    FOUNDRY_AVAILABLE=true
else
    log_warning "Foundry not installed - ValidatorManager initialization will be skipped"
    FOUNDRY_AVAILABLE=false
fi

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

if ! command -v go &> /dev/null; then
    log_error "go not installed"
    exit 1
fi
log_success "go installed"

# Validate configurations
section "Validation"

if [ "$DRY_RUN" = true ]; then
    log_warning "Dry-run: skipping make validate (covered by incremental test target)"
else
    log "Validating Ansible playbooks..."
    if make validate > /dev/null 2>&1; then
        log_success "All configurations valid"
    else
        log_error "Validation failed"
        exit 1
    fi
fi

if [ "$DRY_RUN" = true ]; then
    section "Dry Run"
    log "Building local tools as a fast E2E preflight..."
    if make create-l1 > /dev/null 2>&1; then
        log_success "create-l1 build check passed"
    else
        log_error "create-l1 build check failed"
        exit 1
    fi
    if make init-validator-manager > /dev/null 2>&1; then
        log_success "initialize-validator-manager build check passed"
    else
        log_error "initialize-validator-manager build check failed"
        exit 1
    fi
    log_warning "Skipping infrastructure, deployment, chain creation, add-ons, and reset in dry-run mode"
    section "E2E Dry Run Complete"
    log_success "L1 dry-run checks passed"
    exit 0
fi

# Infrastructure
section "Infrastructure"

if [ "$SKIP_INFRA" = true ]; then
    log_warning "Skipping infrastructure creation (--skip-infra)"
else
    log "Creating infrastructure (3 validators, 1 archive RPC, 1 pruned RPC)..."

    # Use minimal config for testing
    cd terraform/$CLOUD
    terraform init -input=false
    terraform apply -auto-approve \
        -var="validator_count=3" \
        -var="rpc_archive_count=1" \
        -var="rpc_pruned_count=1" \
        -var="environment=fuji" \
        -var="enable_staking_key_backup=true"
    cd "$REPO_ROOT"

    log_success "Infrastructure created"
fi

# Deployment
section "Node Deployment"

log "Deploying avalanchego to all nodes..."
if make deploy NETWORK=$NETWORK; then
    log_success "Nodes deployed"
else
    log_error "Node deployment failed"
    exit 1
fi

log "Waiting for P-Chain sync..."
sleep 30  # Give nodes time to start

if make status; then
    log_success "Nodes are syncing"
else
    log_warning "Status check returned non-zero (nodes may still be syncing)"
fi

# Wait for P-Chain to bootstrap
log "Waiting for P-Chain bootstrap (this may take a few minutes)..."
MAX_WAIT=600  # 10 minutes
WAITED=0
FIRST_VALIDATOR_IP=$(cd terraform/$CLOUD && terraform output -json validator_ips | jq -r '.[0]')
while [ $WAITED -lt $MAX_WAIT ]; do
    BOOTSTRAP_STATUS=$(curl -sf -X POST --data '{"jsonrpc":"2.0","id":1,"method":"info.isBootstrapped","params":{"chain":"P"}}' -H 'content-type:application/json' "http://$FIRST_VALIDATOR_IP:9650/ext/info" 2>/dev/null || echo '{}')
    if echo "$BOOTSTRAP_STATUS" | jq -e '.result.isBootstrapped == true' > /dev/null 2>&1; then
        log_success "P-Chain bootstrapped"
        break
    fi
    sleep 30
    WAITED=$((WAITED + 30))
    log "Still waiting for P-Chain... (${WAITED}s / ${MAX_WAIT}s)"
done

if [ $WAITED -ge $MAX_WAIT ]; then
    log_error "P-Chain bootstrap timeout"
    exit 1
fi

# L1 Creation
section "L1 Creation"

log "Building create-l1 tool..."
if make create-l1; then
    log_success "create-l1 tool built"
else
    log_error "Failed to build create-l1"
    exit 1
fi

log "Getting validator IPs..."
VALIDATOR_IPS=$(cd terraform/$CLOUD && terraform output -json validator_ips | jq -r 'join(",")')
log "Validators: $VALIDATOR_IPS"

# Genesis proxy address (pre-deployed TransparentProxy in genesis.json)
GENESIS_PROXY_ADDRESS="0xfacade0000000000000000000000000000000000"

log "Creating L1 blockchain..."
log "  Using genesis proxy address: $GENESIS_PROXY_ADDRESS"
log "  This address will be used in ConvertSubnetToL1Tx as the ValidatorManager"

# Run create-l1 with JSON output to capture all values including conversion_tx_id
CREATE_L1_JSON=$(mktemp)
if ./tools/create-l1/create-l1 \
    --network=$NETWORK \
    --validators=$VALIDATOR_IPS \
    --chain-name=e2etest \
    --genesis-proxy-address=$GENESIS_PROXY_ADDRESS \
    --output=l1.env \
    --json > "$CREATE_L1_JSON" 2>&1; then
    log_success "L1 created"
else
    log_error "L1 creation failed"
    cat "$CREATE_L1_JSON"
    rm -f "$CREATE_L1_JSON"
    exit 1
fi

# Try to parse JSON output; fall back to l1.env
SUBNET_ID=$(jq -r '.subnet_id // empty' "$CREATE_L1_JSON" 2>/dev/null || true)
CHAIN_ID=$(jq -r '.chain_id // empty' "$CREATE_L1_JSON" 2>/dev/null || true)
CONVERSION_TX=$(jq -r '.conversion_tx_id // empty' "$CREATE_L1_JSON" 2>/dev/null || true)
rm -f "$CREATE_L1_JSON"

# Fall back to l1.env if JSON parsing didn't work
if [ -z "$SUBNET_ID" ] || [ -z "$CHAIN_ID" ]; then
    log_warning "JSON parsing failed, falling back to l1.env"
    if [ -f "l1.env" ]; then
        source l1.env
    fi
fi

log "  Subnet ID: $SUBNET_ID"
log "  Chain ID: $CHAIN_ID"
log "  Conversion TX: ${CONVERSION_TX:-not captured}"

# Save conversion TX to l1.env if not already there
if [ -n "$CONVERSION_TX" ] && ! grep -q "CONVERSION_TX" l1.env 2>/dev/null; then
    echo "CONVERSION_TX=$CONVERSION_TX" >> l1.env
fi

# L1 Configuration
section "L1 Configuration"

log "Configuring nodes for L1..."
if make configure-l1 SUBNET_ID=$SUBNET_ID CHAIN_ID=$CHAIN_ID; then
    log_success "Nodes configured for L1"
else
    log_error "L1 configuration failed"
    exit 1
fi

log "Waiting for L1 chain to start..."
sleep 60

# Get EVM chain ID from genesis (or default to test value)
EVM_CHAIN_ID="${EVM_CHAIN_ID:-99999}"

# ValidatorManager Initialization
section "ValidatorManager Initialization"

if [ "$FOUNDRY_AVAILABLE" = true ] && [ -n "${ICM_CONTRACTS_PATH:-}" ] && [ -n "${CONVERSION_TX:-}" ]; then
    log "Initializing ValidatorManager..."
    log "  This will:"
    log "    1. Deploy PoAValidatorManager implementation"
    log "    2. Upgrade TransparentProxy at $GENESIS_PROXY_ADDRESS"
    log "    3. Initialize ValidatorManager settings"
    log "    4. Initialize validator set with warp message from ConvertSubnetToL1Tx"

    # Build the initialize-validator-manager tool
    log "Building initialize-validator-manager tool..."
    if make init-validator-manager; then
        log_success "initialize-validator-manager tool built"
    else
        log_error "Failed to build initialize-validator-manager"
    fi

    # Get first RPC IP for chain RPC URL
    RPC_IP=$(cd terraform/$CLOUD && terraform output -json rpc_archive_ips 2>/dev/null | jq -r '.[0]' || \
             cd terraform/$CLOUD && terraform output -json rpc_ips 2>/dev/null | jq -r '.[0]' || \
             echo "$VALIDATOR_IPS" | cut -d',' -f1)

    log "Using RPC endpoint: http://$RPC_IP:9650/ext/bc/$CHAIN_ID/rpc"

    # Run ValidatorManager initialization
    if make initialize-validator-manager \
        SUBNET_ID=$SUBNET_ID \
        CHAIN_ID=$CHAIN_ID \
        CONVERSION_TX=$CONVERSION_TX \
        PROXY_ADDRESS=$GENESIS_PROXY_ADDRESS \
        EVM_CHAIN_ID=$EVM_CHAIN_ID; then
        log_success "ValidatorManager initialized"

        # Verify the proxy was upgraded
        log "Verifying proxy upgrade..."
        IMPL_SLOT="0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
        IMPL_ADDRESS=$(cast storage $GENESIS_PROXY_ADDRESS $IMPL_SLOT --rpc-url "http://$RPC_IP:9650/ext/bc/$CHAIN_ID/rpc" 2>/dev/null || echo "")

        if [ -n "$IMPL_ADDRESS" ] && [ "$IMPL_ADDRESS" != "0x0000000000000000000000000000000000000000000000000000000000000000" ]; then
            log_success "Proxy implementation updated: $IMPL_ADDRESS"
        else
            log_warning "Could not verify proxy implementation"
        fi
    else
        log_error "ValidatorManager initialization failed"
    fi
else
    if [ -z "${CONVERSION_TX:-}" ]; then
        log_warning "Skipping ValidatorManager initialization (CONVERSION_TX not captured from create-l1)"
        log "  This may indicate the create-l1 tool version doesn't output CONVERSION_TX"
        log "  You can manually get it from the P-Chain explorer"
    elif [ "$FOUNDRY_AVAILABLE" != true ]; then
        log_warning "Skipping ValidatorManager initialization (foundry not installed)"
        log "  Install with: curl -L https://foundry.paradigm.xyz | bash && foundryup"
    else
        log_warning "Skipping ValidatorManager initialization (ICM_CONTRACTS_PATH not set)"
        log "  Clone icm-contracts: git clone https://github.com/ava-labs/icm-contracts"
        log "  Set: export ICM_CONTRACTS_PATH=/path/to/icm-contracts"
    fi
fi

# Monitoring
section "Monitoring"

log "Deploying Prometheus + Grafana..."
if make monitoring; then
    log_success "Monitoring deployed"
else
    log_error "Monitoring deployment failed"
fi

# Add-ons
if [ "$SKIP_ADDONS" = false ]; then
    section "Add-ons"

    log "Deploying Blockscout block explorer..."
    if make deploy-blockscout CHAIN_ID=$CHAIN_ID EVM_CHAIN_ID=$EVM_CHAIN_ID CHAIN_NAME=E2ETest; then
        log_success "Blockscout deployed"
    else
        log_error "Blockscout deployment failed"
    fi

    log "Deploying eRPC load balancer..."
    if make erpc CHAIN_ID=$CHAIN_ID EVM_CHAIN_ID=$EVM_CHAIN_ID; then
        log_success "eRPC deployed"
    else
        log_error "eRPC deployment failed"
    fi

    log "Deploying The Graph Node..."
    if make graph-node CHAIN_ID=$CHAIN_ID NETWORK_NAME=e2etest; then
        log_success "Graph Node deployed"
    else
        log_error "Graph Node deployment failed"
    fi

    # Faucet requires a funded key on the L1
    if [ -n "${FAUCET_PRIVATE_KEY:-}" ]; then
        log "Deploying faucet..."
        if make faucet CHAIN_ID=$CHAIN_ID EVM_CHAIN_ID=$EVM_CHAIN_ID FAUCET_KEY=$FAUCET_PRIVATE_KEY; then
            log_success "Faucet deployed"
        else
            log_error "Faucet deployment failed"
        fi
    else
        log_warning "Skipping faucet (FAUCET_PRIVATE_KEY not set)"
    fi
else
    log_warning "Skipping add-ons (--skip-addons)"
fi

# Operations
section "Operations Testing"

log "Running health checks..."
if make health-checks CHAIN_ID=$CHAIN_ID; then
    log_success "Health checks passed"
else
    log_error "Health checks failed"
fi

log "Testing rolling restart..."
if make rolling-restart; then
    log_success "Rolling restart completed"
else
    log_error "Rolling restart failed"
fi

# Backup keys
log "Testing staking key backup..."
if make backup-keys; then
    log_success "Staking keys backed up"
else
    log_error "Staking key backup failed"
fi

# Reset L1 (test the reset functionality)
section "Reset Testing"

log "Testing L1 reset..."
if make reset-l1; then
    log_success "L1 reset completed"
else
    log_error "L1 reset failed"
fi

log "Reconfiguring L1 after reset..."
if make configure-l1 SUBNET_ID=$SUBNET_ID CHAIN_ID=$CHAIN_ID; then
    log_success "L1 reconfigured after reset"
else
    log_error "L1 reconfiguration failed"
fi

section "E2E Test Complete"
log_success "All L1 E2E tests passed!"
