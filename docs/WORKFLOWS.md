# Workflow Index

This repository has two primary workflows. Pick one first, then follow its runbook.

## Workflow A: L1 Setup + Add-ons

Use when you are launching an Avalanche L1.

### Outcome

- L1 validator + RPC infrastructure
- AvalancheGo deployed and configured for your L1
- Optional app-layer services (Blockscout, faucet, The Graph, eRPC, Safe)

### Command Flow

```bash
# 1) Provision and deploy nodes
make infra CLOUD=<aws|gcp|azure>
make deploy CLOUD=<aws|gcp|azure> NETWORK=<fuji|mainnet>

# 2) Build/create the L1
make create-l1
./tools/create-l1/create-l1 ... --genesis=configs/l1/genesis/genesis.json --output=l1.env

# 3) Configure nodes for the new L1
source l1.env
make configure-l1 CLOUD=<aws|gcp|azure> SUBNET_ID=$SUBNET_ID CHAIN_ID=$CHAIN_ID
```

### Optional Add-ons

```bash
make deploy-blockscout ...
make faucet ...
make graph-node ...
make erpc ...
make safe-genesis
make safe ...
```

### Primary Docs

- [L1 Deployment](L1-DEPLOYMENT.md)
- [Add-ons](ADD-ONS.md)
- [Safe](SAFE.md)

## Workflow B: Primary Network Validators + Ops

Use when you are operating Avalanche Primary Network validators.

> AWS only in this repository.

### Outcome

- Primary validators deployed with monitoring
- Backup/restore and snapshot tooling
- Migration runbooks and scripts for controlled changes

### Command Flow

```bash
# 1) Provision and deploy
make primary-infra CLOUD=aws
make primary-deploy CLOUD=aws NETWORK=<fuji|mainnet>

# 2) Verify health/sync
make primary-status CLOUD=aws

# 3) Enable day-2 operations
make backup-keys CLOUD=aws
make create-snapshot CLOUD=aws NODE=primary-validator-1
make list-snapshots CLOUD=aws
make prepare-migration CLOUD=aws NODE=migration-target SNAPSHOT=true
make migrate-validator CLOUD=aws SOURCE=primary-validator-1 TARGET=migration-target
```

### Primary Docs

- [Primary Network](PRIMARY-NETWORK.md)
- [Operations](OPERATIONS.md)
- [Troubleshooting](TROUBLESHOOTING.md)

## Shared Guardrails

Run before PRs or production changes:

```bash
make doctor
make lint
make validate
make test-incremental
```

Use this fallback when Terraform provider registry access is restricted:

```bash
make test-incremental SKIP_TERRAFORM_VALIDATE=true
```
