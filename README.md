# Avalanche Deploy

Infrastructure and operations automation for two workflows:

1. L1 setup + optional add-ons (AWS, GCP, Azure)
2. Primary Network validators and maintenance operations (AWS-only)

## Choose A Workflow

### Workflow A: L1 Setup + Bells And Whistles

Use this when you want to launch and run your own Avalanche L1.

Includes:
- Validator and RPC infrastructure provisioning
- AvalancheGo deployment and L1 configuration
- Optional add-ons: Blockscout, faucet, The Graph, eRPC, ICM Relayer, Safe (experimental)

### Quick Start (L1)

```bash
# Pick provider + network
CLOUD=aws
NETWORK=fuji

make setup
make infra CLOUD=$CLOUD
make deploy CLOUD=$CLOUD NETWORK=$NETWORK
make create-l1

# Recommended key flow (platform-cli keystore)
platform keys import --name l1-deployer
platform keys default --name l1-deployer

# Use terraform outputs for validator IPs
VALIDATORS=$(cd terraform/$CLOUD && terraform output -json validator_ips | jq -r 'join(",")')

./tools/create-l1/create-l1 \
  --network=$NETWORK \
  --key-name=l1-deployer \
  --validators="$VALIDATORS" \
  --genesis=configs/l1/genesis/genesis.json \
  --chain-name=my-l1 \
  --output=l1.env

source l1.env
make configure-l1 CLOUD=$CLOUD SUBNET_ID=$SUBNET_ID CHAIN_ID=$CHAIN_ID
make status CLOUD=$CLOUD
```

### L1 Add-ons

```bash
source l1.env

# Block explorer
make deploy-blockscout CLOUD=$CLOUD CHAIN_ID=$CHAIN_ID EVM_CHAIN_ID=$EVM_CHAIN_ID CHAIN_NAME="My L1"

# Faucet
make faucet CLOUD=$CLOUD CHAIN_ID=$CHAIN_ID EVM_CHAIN_ID=$EVM_CHAIN_ID FAUCET_KEY=0x...

# Subgraph indexing
make graph-node CLOUD=$CLOUD CHAIN_ID=$CHAIN_ID NETWORK_NAME=my-l1

# RPC load balancer
make erpc CLOUD=$CLOUD CHAIN_ID=$CHAIN_ID EVM_CHAIN_ID=$EVM_CHAIN_ID

# ICM Relayer (cross-chain messaging)
make icm-relayer CLOUD=$CLOUD SUBNET_ID=$SUBNET_ID CHAIN_ID=$CHAIN_ID RELAYER_KEY=0x...
```

### Workflow B: Primary Network Validators + Ops

Use this when you want production-grade Avalanche Primary Network validators with operational tooling.

Includes:
- Primary validator deployment (AWS)
- Monitoring and health checks
- Staking key backup/restore
- Snapshot-based recovery and validator migration scripts

### Quick Start (Primary Network)

```bash
CLOUD=aws
NETWORK=mainnet

make setup
make primary-infra CLOUD=$CLOUD
make primary-deploy CLOUD=$CLOUD NETWORK=$NETWORK
make primary-status CLOUD=$CLOUD
```

### Day-2 Ops (Primary Network)

```bash
# Security/backup
make backup-keys CLOUD=aws
make restore-keys CLOUD=aws SOURCE=primary-validator-1 TARGET_IP=10.0.1.50

# Snapshots
make create-snapshot CLOUD=aws NODE=primary-validator-1
make list-snapshots CLOUD=aws
make restore-snapshot CLOUD=aws TARGET=migration-target SNAPSHOT=latest

# Migration
make prepare-migration CLOUD=aws NODE=migration-target SNAPSHOT=true
make migrate-validator CLOUD=aws SOURCE=primary-validator-1 TARGET=migration-target
```

Primary Network maintenance targets are guarded to `CLOUD=aws`.

## Guardrails And Testing

Run these before pushing changes:

```bash
make doctor
make lint
make validate
make test-unit
make test-e2e-dry
make test-incremental
```

If your environment cannot reach Terraform provider registries:

```bash
make test-incremental SKIP_TERRAFORM_VALIDATE=true
```

## Command Help

```bash
make help
make help-l1
make help-primary
make k8s-help
make help-all
```

## Repo Layout

```text
configs/      Runtime config and genesis files (L1 + Primary Network)
  examples/   Starter templates (for example, deploy.yaml.example)
terraform/    Provider infrastructure roots (aws/gcp/azure)
ansible/      Deployment and operations playbooks/roles
scripts/      Operator helper scripts (status, backup, snapshots, migration)
tools/        Go CLIs (create-l1, initialize-validator-manager)
tests/        E2E and dry-run tests
kubernetes/   Optional Kubernetes deployment path
docs/         Runbooks and reference docs
```

## Documentation

- [Workflow Index](docs/WORKFLOWS.md) - Which path to use and in what order
- [L1 Deployment](docs/L1-DEPLOYMENT.md) - Full L1 runbook
- [Add-ons](docs/ADD-ONS.md) - Blockscout, faucet, eRPC, The Graph, ICM Relayer, Safe
- [Primary Network](docs/PRIMARY-NETWORK.md) - Validator deployment, snapshots, migration
- [Operations](docs/OPERATIONS.md) - Day-2 commands and references
- [Troubleshooting](docs/TROUBLESHOOTING.md) - Common issues and fixes
- [Security](SECURITY.md) - Security expectations and guidelines

## Prerequisites

```bash
# Required versions:
# - Go 1.24.13+
# - Terraform 1.5+
# - Ansible 2.15+
brew install terraform ansible awscli jq go shellcheck
# or: make setup
```

## Cloud Provider Notes

- L1 workflows support `CLOUD=aws|gcp|azure`.
- Primary Network workflows are currently `CLOUD=aws` only.
- AWS has dedicated `rpc_archive` + `rpc_pruned` inventory groups.
- GCP and Azure currently use a single `rpc` inventory group.
