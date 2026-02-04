# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository automates deploying Avalanche L1 blockchains (formerly subnets) on Fuji testnet or Mainnet. It supports two deployment paths:
1. **Terraform + Ansible** - Creates cloud VMs (AWS/GCP/Azure) and installs avalanchego
2. **Kubernetes** - Deploys to existing K8s clusters via Helm

## Common Commands

```bash
# Install dependencies (terraform, ansible, aws-cli, jq)
make setup

# Create cloud infrastructure (defaults to AWS)
make infra                    # AWS
make infra CLOUD=gcp          # GCP
make infra CLOUD=azure        # Azure

# Deploy avalanchego nodes
make deploy                   # Fuji
make deploy NETWORK=mainnet   # Mainnet

# Check node sync status
make status

# Build the L1 creation tool
make create-l1

# Configure nodes after L1 creation
make configure-l1 SUBNET_ID=<id> CHAIN_ID=<id>

# Reset L1 for redeployment (wipes chain data, keeps staking keys)
make reset-l1

# Setup monitoring (Prometheus + Grafana)
make monitoring

# View avalanchego logs
make logs

# Destroy infrastructure (STOPS BILLING)
make destroy
```

## Operations Commands

```bash
# Upgrade avalanchego (zero-downtime rolling upgrade)
# NOTE: subnet-evm is bundled with avalanchego v1.12.0+ and updates automatically
make upgrade VERSION=1.12.0

# Rolling restart (zero-downtime)
make rolling-restart

# Health checks (comprehensive node status)
make health-checks
make health-checks CHAIN_ID=<id>

# Deploy token faucet
make faucet CHAIN_ID=<id> EVM_CHAIN_ID=<evm-id> FAUCET_KEY=0x...

# Deploy block explorer
make deploy-blockscout CHAIN_ID=<id> EVM_CHAIN_ID=<evm-id>

# Deploy The Graph Node (for subgraph indexing)
make graph-node CHAIN_ID=<id> NETWORK_NAME=my-l1

# Deploy eRPC load balancer (caching + failover)
make erpc CHAIN_ID=<id> EVM_CHAIN_ID=<evm-id>
```

## Architecture

```
.
├── terraform/           # Infrastructure as code
│   ├── aws/            # AWS-specific config
│   ├── gcp/            # GCP-specific config
│   ├── azure/          # Azure-specific config
│   └── modules/        # Shared compute/networking modules
├── ansible/            # Configuration management
│   ├── playbooks/      # Deployment and operations playbooks
│   │   ├── 00-reset-l1.yml          # Reset for redeployment
│   │   ├── 01-deploy-nodes.yml      # Install avalanchego
│   │   ├── 02-configure-l1.yml      # Add subnet tracking
│   │   ├── 03-setup-monitoring.yml  # Prometheus/Grafana
│   │   ├── 04-deploy-blockscout.yml # Block explorer
│   │   ├── 05-deploy-safe.yml       # Safe multisig (experimental)
│   │   ├── 06-deploy-faucet.yml     # Token faucet
│   │   ├── 07-deploy-graph-node.yml # The Graph Node (indexing)
│   │   ├── 08-deploy-erpc.yml       # eRPC load balancer
│   │   ├── rolling-restart.yml      # Zero-downtime restart
│   │   ├── upgrade-nodes.yml        # Version upgrades
│   │   └── health-checks.yml        # Comprehensive health checks
│   └── roles/          # avalanchego, prometheus, grafana, faucet, blockscout, safe, graph_node, erpc
├── tools/create-l1/    # Go CLI for L1 creation (supports --json output)
├── shared/             # Genesis templates, configs, dashboards
└── scripts/            # status.sh, wait-for-sync.sh
```

## Key Workflows

### Terraform outputs Ansible inventory
Terraform auto-generates `ansible/inventory/aws_hosts` (or gcp/azure variants) with node IPs and SSH key paths.

### Three-phase Ansible deployment
1. `01-deploy-nodes.yml` - Installs avalanchego, generates staking keys, starts syncing
2. `02-configure-l1.yml` - Adds `track-subnets` config after L1 creation
3. `03-setup-monitoring.yml` - Deploys Prometheus and Grafana

### create-l1 tool
Go program in `tools/create-l1/` that issues P-Chain transactions:
1. CreateSubnetTx
2. CreateChainTx (with genesis and SubnetEVM)
3. ConvertSubnetToL1Tx (registers validators)

Outputs `l1.env` with SUBNET_ID and CHAIN_ID.

**JSON Output for Scripting:**
```bash
./create-l1 --json --validators=1.2.3.4,5.6.7.8 --genesis=genesis.json
```
Returns structured JSON with subnet_id, chain_id, validators, rpc_endpoints for CI/CD integration.

## Environment Variables

```bash
# AWS credentials (required for AWS deployment)
AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN

# P-Chain private key (required for create-l1)
AVALANCHE_PRIVATE_KEY=PrivateKey-...

# Optional: validator balance in AVAX (default: 1)
L1_VALIDATOR_BALANCE_AVAX=5

# Validator IPs (alternative to --validators flag)
VALIDATOR_1_IP, VALIDATOR_2_IP, VALIDATOR_3_IP
```

## Genesis Configuration

Edit `genesis.json` in repo root. Key fields:
- `chainId` - Unique chain ID (check chainlist.org)
- `feeConfig.minBaseFee` - Minimum gas price in wei
- `feeConfig.targetBlockRate` - Target seconds between blocks
- `alloc` - Pre-funded addresses (balance in wei, hex format)

See `GENESIS.md` for detailed configuration options.

## Building the Go Tool

```bash
cd tools/create-l1
go mod tidy
go build -o create-l1 .
```

Requires Go 1.21+. Uses avalanchego SDK for wallet/transaction operations.
