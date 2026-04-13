#!/bin/bash
#
# E2E Test: L1 Blockchain Deployment
#
# Tests the complete L1 deployment lifecycle including:
# - Infrastructure creation (Terraform AWS)
# - Node deployment (Ansible + avalanchego)
# - L1 creation (create-l1 tool: CreateSubnet, CreateChain, ConvertSubnetToL1)
# - ValidatorManager deployment and initialization
# - L1 chain verification
# - Monitoring (Prometheus + Grafana)
# - Add-ons:
#   - Blockscout block explorer
#   - eRPC load balancer
#   - The Graph Node
#   - Faucet (ewoq key, always runs)
#   - Safe multisig infrastructure
#   - ICM Relayer (if RELAYER_KEY set)
# - Operations:
#   - Health checks
#   - Rolling restart
#   - Rolling upgrade
#   - Staking key backup
# - L1 reset and reconfiguration
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
# Optional:
#   TF_VARFILE           Path to terraform .tfvars file (e.g., tests/ci/l1.tfvars)
#   RELAYER_KEY          Funded key for ICM Relayer (must be funded on L1 + C-Chain)
#   ICM_CONTRACTS_PATH   Path to icm-contracts repo (auto-cloned if not set)
#   GLACIER_API_KEY      For signature aggregation (or uses local sig-agg)
#   UPGRADE_VERSION      avalanchego version to upgrade to (skipped if not set)
#
# Note: In --dry-run mode, credentials are not required.
# Note: Faucet uses the ewoq key (pre-funded in genesis). No separate key needed.
#
# Genesis Configuration:
#   The genesis file (default: configs/l1/genesis/genesis.json) must have a pre-deployed
#   TransparentProxy at 0xfacade0000000000000000000000000000000000 with ProxyAdmin at
#   0xdad0000000000000000000000000000000000000. These are used by ConvertSubnetToL1Tx
#   and ValidatorManager initialization.

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
TF_VARFILE="${TF_VARFILE:-}"
UPGRADE_VERSION="${UPGRADE_VERSION:-}"

# Well-known ewoq private key (pre-funded in standard SubnetEVM genesis)
EWOQ_PRIVATE_KEY="0x56289e99c94b6912bfc12adc093c9b51124f0dc54ac7a766b2bc5ccf558d8027"

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

# Health check helper: retries a URL until it responds 2xx
check_health() {
    local url="$1"
    local name="$2"
    local retries="${3:-12}"
    local delay="${4:-10}"
    local attempt=0
    while [ $attempt -lt $retries ]; do
        if curl -sf --max-time 5 "$url" > /dev/null 2>&1; then
            log_success "$name health check passed"
            return 0
        fi
        attempt=$((attempt + 1))
        if [ $attempt -lt $retries ]; then
            sleep "$delay"
        fi
    done
    log_error "$name health check failed after ${retries} attempts ($url)"
    return 1
}

cleanup() {
    if [ "$SKIP_DESTROY" = false ]; then
        section "Cleanup"
        log "Destroying infrastructure..."
        make destroy CLOUD=$CLOUD AUTO_APPROVE=true || log_warning "Destroy failed (may already be destroyed)"
    else
        log_warning "Skipping destroy (--skip-destroy)"
    fi

    # Clean up cloned icm-contracts if we created it
    if [ -n "${ICM_CLONE_DIR:-}" ] && [ -d "${ICM_CLONE_DIR:-}" ]; then
        rm -rf "$ICM_CLONE_DIR"
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

# ──────────────────────────────────────────────────────────
# Preflight Checks
# ──────────────────────────────────────────────────────────
section "Preflight Checks"

if [ "$DRY_RUN" = true ]; then
    log_warning "Dry-run mode enabled: skipping cloud operations"
fi

# AWS credentials
if [ "$DRY_RUN" = false ]; then
    if [ "$CLOUD" != "aws" ]; then
        log_error "This E2E workflow currently supports CLOUD=aws only"
        exit 1
    fi
    if [ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ]; then
        log_success "AWS credentials configured (env vars)"
    elif aws sts get-caller-identity &>/dev/null; then
        log_success "AWS credentials configured (SSO/profile)"
    else
        log_error "No AWS credentials found"
        exit 1
    fi
else
    log_success "Dry-run: skipping AWS credential check"
fi

# Avalanche P-Chain key
if [ "$DRY_RUN" = false ]; then
    if [ -z "${AVALANCHE_PRIVATE_KEY:-}" ]; then
        log_error "AVALANCHE_PRIVATE_KEY not set (need funded Fuji P-Chain key)"
        exit 1
    fi
    log_success "Avalanche private key configured"
else
    log_success "Dry-run: skipping P-Chain key check"
fi

# Foundry (forge/cast) - required for ValidatorManager
if [ "$DRY_RUN" = false ]; then
    if ! command -v forge &> /dev/null || ! command -v cast &> /dev/null; then
        log "Foundry not found, installing..."
        if curl -L https://foundry.paradigm.xyz 2>/dev/null | bash 2>/dev/null; then
            export PATH="$HOME/.foundry/bin:$PATH"
            foundryup 2>/dev/null || true
        fi
    fi
    if command -v forge &> /dev/null && command -v cast &> /dev/null; then
        log_success "Foundry (forge/cast) available"
    else
        log_error "Foundry installation failed - ValidatorManager tests will fail"
    fi
else
    log_success "Dry-run: skipping Foundry check"
fi

# ICM contracts - required for ValidatorManager
ICM_CLONE_DIR=""
if [ "$DRY_RUN" = false ]; then
    if [ -z "${ICM_CONTRACTS_PATH:-}" ]; then
        for path in ~/code/icm-contracts ../icm-contracts ../../icm-contracts; do
            if [ -d "$path" ]; then
                export ICM_CONTRACTS_PATH="$path"
                break
            fi
        done
    fi
    if [ -z "${ICM_CONTRACTS_PATH:-}" ] || [ ! -d "${ICM_CONTRACTS_PATH:-}" ]; then
        log "ICM contracts not found, cloning..."
        ICM_CLONE_DIR="/tmp/icm-contracts-$$"
        if git clone --depth 1 https://github.com/ava-labs/icm-contracts "$ICM_CLONE_DIR" 2>/dev/null; then
            export ICM_CONTRACTS_PATH="$ICM_CLONE_DIR"
            log_success "ICM contracts cloned to $ICM_CLONE_DIR"
        else
            log_error "Failed to clone icm-contracts - ValidatorManager tests will fail"
        fi
    else
        log_success "ICM contracts: $ICM_CONTRACTS_PATH"
    fi
else
    log_success "Dry-run: skipping ICM contracts check"
fi

# Core tools
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

# Optional: Relayer key
if [ -n "${RELAYER_KEY:-}" ]; then
    log_success "ICM Relayer key configured"
else
    log_warning "RELAYER_KEY not set - ICM Relayer will be skipped"
fi

# Terraform var file
if [ -n "$TF_VARFILE" ]; then
    if [ -f "$TF_VARFILE" ] || [ -f "$REPO_ROOT/$TF_VARFILE" ]; then
        log_success "Terraform var file: $TF_VARFILE"
    else
        log_error "TF_VARFILE not found: $TF_VARFILE"
        exit 1
    fi
fi

# ──────────────────────────────────────────────────────────
# Validation
# ──────────────────────────────────────────────────────────
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

# ──────────────────────────────────────────────────────────
# Infrastructure
# ──────────────────────────────────────────────────────────
section "Infrastructure"

if [ "$SKIP_INFRA" = true ]; then
    log_warning "Skipping infrastructure creation (--skip-infra)"
else
    log "Creating infrastructure..."

    # Resolve TF_VARFILE to absolute path before cd
    RESOLVED_VARFILE=""
    if [ -n "$TF_VARFILE" ]; then
        if [ -f "$TF_VARFILE" ]; then
            RESOLVED_VARFILE="$(cd "$(dirname "$TF_VARFILE")" && pwd)/$(basename "$TF_VARFILE")"
        elif [ -f "$REPO_ROOT/$TF_VARFILE" ]; then
            RESOLVED_VARFILE="$REPO_ROOT/$TF_VARFILE"
        fi
    fi

    cd terraform/l1/$CLOUD
    terraform init -input=false
    if [ -n "$RESOLVED_VARFILE" ]; then
        terraform apply -auto-approve -var-file="$RESOLVED_VARFILE"
    else
        terraform apply -auto-approve \
            -var="validator_count=3" \
            -var="rpc_archive_count=1" \
            -var="rpc_pruned_count=1" \
            -var="environment=fuji" \
            -var="enable_staking_key_backup=true"
    fi
    cd "$REPO_ROOT"

    log_success "Infrastructure created"
fi

# Capture node IPs
log "Collecting node IPs..."
FIRST_VALIDATOR_IP=$(cd terraform/l1/$CLOUD && terraform output -json validator_ips | jq -r '.[0]')
VALIDATOR_IPS=$(cd terraform/l1/$CLOUD && terraform output -json validator_ips | jq -r 'join(",")')
RPC_IP=$(cd terraform/l1/$CLOUD && terraform output -json rpc_archive_ips 2>/dev/null | jq -r '.[0]' 2>/dev/null || echo "")
if [ -z "$RPC_IP" ] || [ "$RPC_IP" = "null" ]; then
    RPC_IP=$(cd terraform/l1/$CLOUD && terraform output -json rpc_ips 2>/dev/null | jq -r '.[0]' 2>/dev/null || echo "$FIRST_VALIDATOR_IP")
fi
MONITORING_IP=$(cd terraform/l1/$CLOUD && terraform output -raw monitoring_ip 2>/dev/null || echo "")

log "  Validators: $VALIDATOR_IPS"
log "  RPC (archive): $RPC_IP"
log "  Monitoring: ${MONITORING_IP:-none}"

# ──────────────────────────────────────────────────────────
# Node Deployment
# ──────────────────────────────────────────────────────────
section "Node Deployment"

log "Deploying avalanchego to all nodes..."
if make deploy NETWORK=$NETWORK; then
    log_success "Nodes deployed"
else
    log_error "Node deployment failed"
    exit 1
fi

log "Waiting for P-Chain sync..."
sleep 30

if make status; then
    log_success "Nodes are syncing"
else
    log_warning "Status check returned non-zero (nodes may still be syncing)"
fi

# Wait for P-Chain to bootstrap
log "Waiting for P-Chain bootstrap (this may take a few minutes)..."
MAX_WAIT=600  # 10 minutes
WAITED=0
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

# ──────────────────────────────────────────────────────────
# L1 Creation
# ──────────────────────────────────────────────────────────
section "L1 Creation"

log "Building create-l1 tool..."
if make create-l1; then
    log_success "create-l1 tool built"
else
    log_error "Failed to build create-l1"
    exit 1
fi

log "Validators: $VALIDATOR_IPS"

# Genesis proxy address (pre-deployed TransparentProxy in genesis file)
GENESIS_PROXY_ADDRESS="0xfacade0000000000000000000000000000000000"

log "Creating L1 blockchain..."
log "  Genesis proxy address: $GENESIS_PROXY_ADDRESS"

if ./tools/create-l1/create-l1 \
    --network=$NETWORK \
    --validators=$VALIDATOR_IPS \
    --chain-name=e2etest \
    --genesis-proxy-address=$GENESIS_PROXY_ADDRESS \
    --output=l1.env; then
    log_success "L1 created"
else
    log_error "L1 creation failed"
    exit 1
fi

# Source l1.env for SUBNET_ID, CHAIN_ID, CONVERSION_TX, EVM_CHAIN_ID
if [ -f "l1.env" ]; then
    source l1.env
else
    log_error "l1.env not found after create-l1"
    exit 1
fi

EVM_CHAIN_ID="${EVM_CHAIN_ID:-99999}"

log "  Subnet ID: $SUBNET_ID"
log "  Chain ID: $CHAIN_ID"
log "  EVM Chain ID: $EVM_CHAIN_ID"
log "  Conversion TX: ${CONVERSION_TX:-not captured}"

# ──────────────────────────────────────────────────────────
# L1 Configuration
# ──────────────────────────────────────────────────────────
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

# Verify L1 chain is responding
L1_RPC_URL="http://$RPC_IP:9650/ext/bc/$CHAIN_ID/rpc"
log "Verifying L1 chain at $L1_RPC_URL..."
L1_VERIFIED=false
for i in $(seq 1 12); do
    BLOCK_NUM=$(curl -sf -X POST \
        --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
        -H 'content-type:application/json' "$L1_RPC_URL" 2>/dev/null \
        | jq -r '.result // empty' 2>/dev/null || true)
    if [ -n "$BLOCK_NUM" ]; then
        log_success "L1 chain responding (block: $BLOCK_NUM)"
        L1_VERIFIED=true
        break
    fi
    sleep 10
done
if [ "$L1_VERIFIED" = false ]; then
    log_error "L1 chain not responding after 120s"
fi

# ──────────────────────────────────────────────────────────
# ValidatorManager Initialization
# ──────────────────────────────────────────────────────────
section "ValidatorManager Initialization"

log "Building initialize-validator-manager tool..."
if make init-validator-manager; then
    log_success "initialize-validator-manager tool built"
else
    log_error "Failed to build initialize-validator-manager"
    # Skip ValidatorManager initialization entirely if build failed
    CONVERSION_TX=""
fi

if [ -z "${CONVERSION_TX:-}" ]; then
    log_error "CONVERSION_TX not captured - cannot initialize ValidatorManager"
else
    log "Initializing ValidatorManager..."
    log "  1. Deploy PoAValidatorManager implementation"
    log "  2. Upgrade TransparentProxy at $GENESIS_PROXY_ADDRESS"
    log "  3. Initialize ValidatorManager settings"
    log "  4. Initialize validator set with warp message"

    if make initialize-validator-manager \
        SUBNET_ID=$SUBNET_ID \
        CHAIN_ID=$CHAIN_ID \
        CONVERSION_TX=$CONVERSION_TX \
        PROXY_ADDRESS=$GENESIS_PROXY_ADDRESS \
        EVM_CHAIN_ID=$EVM_CHAIN_ID; then
        log_success "ValidatorManager initialized"

        # Verify proxy implementation was set
        log "Verifying proxy upgrade..."
        IMPL_SLOT="0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
        IMPL_ADDRESS=$(cast storage "$GENESIS_PROXY_ADDRESS" "$IMPL_SLOT" --rpc-url "$L1_RPC_URL" 2>/dev/null || echo "")

        if [ -n "$IMPL_ADDRESS" ] && [ "$IMPL_ADDRESS" != "0x0000000000000000000000000000000000000000000000000000000000000000" ]; then
            log_success "Proxy implementation set: $IMPL_ADDRESS"
        else
            log_error "Proxy implementation not set"
        fi
    else
        log_error "ValidatorManager initialization failed"
    fi
fi

# ──────────────────────────────────────────────────────────
# Monitoring
# ──────────────────────────────────────────────────────────
section "Monitoring"

log "Deploying Prometheus + Grafana..."
if make monitoring; then
    log_success "Monitoring deployed"
    if [ -n "$MONITORING_IP" ]; then
        check_health "http://$MONITORING_IP:3000/api/health" "Grafana" 6 10 || true
    fi
else
    log_error "Monitoring deployment failed"
fi

# ──────────────────────────────────────────────────────────
# Add-ons
# ──────────────────────────────────────────────────────────
if [ "$SKIP_ADDONS" = false ]; then
    section "Add-ons"

    # --- Blockscout block explorer ---
    log "Deploying Blockscout block explorer..."
    if make deploy-blockscout CHAIN_ID=$CHAIN_ID EVM_CHAIN_ID=$EVM_CHAIN_ID CHAIN_NAME=E2ETest; then
        log_success "Blockscout deployed"
        check_health "http://$RPC_IP:4001" "Blockscout" 12 10 || true
    else
        log_error "Blockscout deployment failed"
    fi

    # --- eRPC load balancer ---
    log "Deploying eRPC load balancer..."
    if make erpc CHAIN_ID=$CHAIN_ID EVM_CHAIN_ID=$EVM_CHAIN_ID; then
        log_success "eRPC deployed"
        ERPC_HOST="${MONITORING_IP:-$RPC_IP}"
        check_health "http://$ERPC_HOST:4000" "eRPC" 6 10 || true
    else
        log_error "eRPC deployment failed"
    fi

    # --- The Graph Node ---
    log "Deploying The Graph Node..."
    if make graph-node CHAIN_ID=$CHAIN_ID NETWORK_NAME=e2etest; then
        log_success "Graph Node deployed"
        check_health "http://$RPC_IP:8030/graphql" "Graph Node" 12 10 || true
    else
        log_error "Graph Node deployment failed"
    fi

    # --- Faucet (ewoq key - always funded in genesis) ---
    log "Deploying faucet (ewoq key)..."
    if make faucet CHAIN_ID=$CHAIN_ID EVM_CHAIN_ID=$EVM_CHAIN_ID FAUCET_KEY=$EWOQ_PRIVATE_KEY; then
        log_success "Faucet deployed"
        check_health "http://$RPC_IP:8010/health" "Faucet" 6 10 || true
    else
        log_error "Faucet deployment failed"
    fi

    # --- Safe multisig infrastructure ---
    log "Deploying Safe multisig infrastructure..."
    if make safe CHAIN_ID=$CHAIN_ID EVM_CHAIN_ID=$EVM_CHAIN_ID CHAIN_NAME=E2ETest; then
        log_success "Safe infrastructure deployed"
        check_health "http://$RPC_IP:3000" "Safe UI" 18 10 || true
        check_health "http://$RPC_IP:8003/health" "Safe Client Gateway" 12 10 || true
    else
        log_error "Safe deployment failed"
    fi

    # --- ICM Relayer (conditional on RELAYER_KEY) ---
    if [ -n "${RELAYER_KEY:-}" ]; then
        log "Deploying ICM Relayer..."
        if make icm-relayer SUBNET_ID=$SUBNET_ID CHAIN_ID=$CHAIN_ID RELAYER_KEY=$RELAYER_KEY; then
            log_success "ICM Relayer deployed"
            check_health "http://$RPC_IP:8080/health" "ICM Relayer" 6 10 || true
        else
            log_error "ICM Relayer deployment failed"
        fi
    else
        log_warning "Skipping ICM Relayer (RELAYER_KEY not set)"
    fi
else
    log_warning "Skipping add-ons (--skip-addons)"
fi

# ──────────────────────────────────────────────────────────
# Operations Testing
# ──────────────────────────────────────────────────────────
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

# Verify L1 chain survived rolling restart
sleep 15
if curl -sf -X POST \
    --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
    -H 'content-type:application/json' "$L1_RPC_URL" 2>/dev/null \
    | jq -e '.result' > /dev/null 2>&1; then
    log_success "L1 chain healthy after rolling restart"
else
    log_error "L1 chain not responding after rolling restart"
fi

# Upgrade test
if [ -n "$UPGRADE_VERSION" ]; then
    section "Upgrade Test"

    CURRENT_VERSION=$(curl -sf "http://$FIRST_VALIDATOR_IP:9650/ext/info" \
        -X POST -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","id":1,"method":"info.getNodeVersion"}' \
        2>/dev/null | jq -r '.result.version' || echo "unknown")
    log "Current version: $CURRENT_VERSION"

    log "Upgrading to avalanchego v${UPGRADE_VERSION}..."
    if make upgrade VERSION=$UPGRADE_VERSION; then
        log_success "Upgrade completed"
    else
        log_error "Upgrade to v${UPGRADE_VERSION} failed"
    fi

    sleep 15

    UPGRADED_VERSION=$(curl -sf "http://$FIRST_VALIDATOR_IP:9650/ext/info" \
        -X POST -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","id":1,"method":"info.getNodeVersion"}' \
        2>/dev/null | jq -r '.result.version' || echo "unknown")

    if echo "$UPGRADED_VERSION" | grep -q "$UPGRADE_VERSION"; then
        log_success "Version verified: $UPGRADED_VERSION"
    else
        log_error "Version mismatch: expected v${UPGRADE_VERSION}, got $UPGRADED_VERSION"
    fi

    # Verify L1 chain survived upgrade
    sleep 30
    if curl -sf -X POST \
        --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
        -H 'content-type:application/json' "$L1_RPC_URL" 2>/dev/null \
        | jq -e '.result' > /dev/null 2>&1; then
        log_success "L1 chain healthy after upgrade"
    else
        log_error "L1 chain not responding after upgrade"
    fi

    if make health-checks CHAIN_ID=$CHAIN_ID; then
        log_success "Health checks passed after upgrade"
    else
        log_error "Health checks failed after upgrade"
    fi
else
    log_warning "Skipping upgrade test (UPGRADE_VERSION not set)"
fi

# Note: L1 staking keys are automatically backed up to S3 during deploy-nodes.yml
# (when enable_staking_key_backup=true). No separate backup step needed.

# ──────────────────────────────────────────────────────────
# Reset Testing
# ──────────────────────────────────────────────────────────
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
