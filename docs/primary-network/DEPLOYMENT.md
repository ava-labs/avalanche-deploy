# Primary Network Validator Guide

Deploy and operate Avalanche Primary Network validators with enterprise-grade features.

> **Scope:** Primary Network workflows in this repo are currently supported on AWS only.

## Architecture

```mermaid
flowchart TB
    subgraph Internet
        PrimaryNetwork([Avalanche Primary Network<br/>P-Chain / X-Chain / C-Chain])
        Operator([Operator])
    end

    subgraph AWS["AWS Cloud"]
        subgraph VPC["VPC (10.0.0.0/16)"]
            subgraph PrimaryValidatorsSG["primary-validators-sg"]
                PV1[Primary Validator<br/>i4i.xlarge<br/>937GB NVMe<br/>:9651 P2P]
                PV2[Primary Validator 2<br/>i4i.xlarge<br/>937GB NVMe<br/>:9651 P2P]
            end

            subgraph MonitoringSG["monitoring-sg"]
                Prometheus[Prometheus<br/>:9090]
                Grafana[Grafana<br/>:3000]
            end
        end

        subgraph Storage["S3 + KMS"]
            S3[(S3 Bucket<br/>Staking Keys<br/>KMS Encrypted)]
        end
    end

    PrimaryNetwork <-->|P2P :9651| PV1
    PrimaryNetwork <-->|P2P :9651| PV2
    PV1 <-->|P2P :9651| PV2

    Operator -->|SSH :22| PV1
    Operator -->|API :9650| PV1
    Operator -->|Dashboard :3000| Grafana

    PV1 -.->|backup| S3
    PV2 -.->|backup| S3

    PV1 -.->|metrics| Prometheus
    PV2 -.->|metrics| Prometheus
    Prometheus -.-> Grafana
```

## Features

- **High-performance storage**: i4i.xlarge instances with 937GB NVMe
- **Staking key backup**: Automatic S3 backup with KMS encryption
- **Near-zero downtime migration**: Transfer validators to new instances
- **Database snapshots**: Fast bootstrapping for new nodes
- **Full chain sync**: Complete P/X/C chain data

## Quick Start

### 1. Create Infrastructure

```bash
make primary-infra CLOUD=aws
```

### 2. Deploy Validators

```bash
make primary-deploy CLOUD=aws NETWORK=fuji  # or mainnet
```

### 3. Wait for Sync

```bash
make primary-status CLOUD=aws
# Takes 2-4 hours for state-sync
```

### 4. Register on P-Chain

Use [Core Wallet](https://core.app/) or avalanche-cli to register your validator.

### 5. Backup Keys

```bash
make backup-keys CLOUD=aws
```

## Staking Key Management

```bash
# Backup all validator keys to S3
make backup-keys CLOUD=aws

# Restore keys to a specific node
make restore-keys CLOUD=aws SOURCE=primary-validator-1 TARGET_IP=10.0.1.50

# List backups
aws s3 ls s3://$(terraform -chdir=terraform/primary-network/aws output -raw staking_keys_bucket)/
```

## Database Snapshots

Create snapshots of synced nodes for faster bootstrapping:

```bash
# Create a snapshot from a synced validator
make create-snapshot CLOUD=aws NODE=primary-validator-1

# Create with custom name
make create-snapshot CLOUD=aws NODE=primary-validator-1 NAME=mainnet-2025-02

# List available snapshots
make list-snapshots CLOUD=aws

# Restore snapshot to a node
make restore-snapshot CLOUD=aws TARGET=migration-target
make restore-snapshot CLOUD=aws TARGET=migration-target SNAPSHOT=mainnet-2025-02

# Restore with integrity verification (slower but safer)
cd ansible && ansible-playbook -i inventory/aws_hosts playbooks/primary-network/restore-snapshot.yml \
  --limit migration-target \
  -e verify_integrity=true
```

Snapshots are stored in S3 with KMS encryption and SHA256 checksums. A **pruned mainnet snapshot is ~400GB** and restores in minutes vs hours for state sync.

## Validator Migration

Migrate a validator to a new instance with minimal downtime (~30 seconds):

```mermaid
sequenceDiagram
    participant Old as Old Validator
    participant S3 as S3 (Staking Keys)
    participant New as New Validator
    participant Network as Primary Network

    Note over Old,Network: Normal Operation
    Old->>Network: Validating (active)

    Note over New: Phase 1: Sync New Node
    New->>Network: State-sync (no keys)
    New-->>New: Bootstrap P/X/C chains

    Note over Old,S3: Phase 2: Backup Keys
    Old->>S3: Upload staking keys (KMS encrypted)

    Note over New,S3: Phase 3: Prepare Migration
    New->>S3: Download staking keys
    New-->>New: Stop avalanchego

    Note over Old,New: Phase 4: Execute Migration (~30s downtime)
    Old-->>Old: Stop avalanchego
    New-->>New: Start with staking keys
    New->>Network: Validating (same NodeID)

    Note over New,Network: Migration Complete
```

### Migration Steps

```bash
# 1. Add new instance to inventory as 'migration-target'

# 2. Prepare the new node
# Option A: Using snapshot (faster - minutes)
make prepare-migration CLOUD=aws NODE=migration-target SNAPSHOT=true

# Option B: Using state-sync (slower - hours)
make prepare-migration CLOUD=aws NODE=migration-target

# 3. Wait for sync to complete
./scripts/primary-network/check-sync.sh <new-node-ip>

# 4. Execute migration (~30s downtime)
make migrate-validator CLOUD=aws SOURCE=primary-validator-1 TARGET=migration-target
```

## Cost Estimate

| Component | Instance | Storage | Monthly (us-east-1) |
|-----------|----------|---------|---------------------|
| Primary Validator | i4i.xlarge | 937GB NVMe | ~$310 |
| S3 + KMS | - | ~1GB | ~$1 |
| Monitoring | t3.small | 50GB | ~$15 |
| **Total per validator** | | | **~$326/mo** |

## Terraform Configuration

Edit `terraform/primary-network/aws/terraform.tfvars`:

```hcl
primary_validator_count = 1    # Number of Primary Network validators
enable_staking_key_backup = true  # S3 backup for staking keys
```

Primary validator runtime config is stored at:
`configs/primary-network/node/primary-validator-node-config.json`

## Kubernetes Alternative

This guide covers the Terraform + Ansible path (AWS). To deploy Primary Network nodes on an existing Kubernetes cluster instead, see the [Kubernetes deployment guide](../../kubernetes/README.md).

## Next Steps

- [Operations guide](../OPERATIONS.md) (upgrades, monitoring, health checks)
- [Troubleshooting](../TROUBLESHOOTING.md)
