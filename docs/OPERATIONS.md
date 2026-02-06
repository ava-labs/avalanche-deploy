# Operations & Maintenance Guide

Day-2 operations for your Avalanche infrastructure.

## Health Checks

```bash
# Comprehensive health checks on all nodes
make health-checks

# Include L1 chain status
make health-checks CHAIN_ID=$CHAIN_ID
```

## Rolling Restart

Restart nodes one at a time with health checks (zero downtime):

```bash
make rolling-restart
```

## Upgrading Avalanchego

Zero-downtime version upgrades:

```bash
make upgrade VERSION=1.12.0
```

> **Note:** subnet-evm is bundled with avalanchego v1.12.0+ and updates automatically.

## Monitoring

Deploy Prometheus + Grafana:

```bash
make monitoring
# Access: http://<monitoring-ip>:3000 (admin/admin)
```

Pre-configured dashboards include:
- Node health and sync status
- P2P network metrics
- Chain-specific metrics
- Resource utilization

## Viewing Logs

```bash
make logs
```

Or SSH directly:
```bash
ssh -i ~/.ssh/avalanche-deploy ubuntu@<node-ip> \
  "sudo journalctl -u avalanchego -f --no-pager -n 50"
```

## Reset L1 Chain Data

Wipe L1 chain data for redeployment (keeps staking keys):

```bash
make reset-l1
```

## Commands Reference

### L1 Infrastructure & Deployment

| Command | Description |
|---------|-------------|
| `make setup` | Install terraform, ansible, aws-cli, jq, go |
| `make infra` | Create L1 cloud infrastructure |
| `make deploy` | Install avalanchego on L1 nodes |
| `make create-l1` | Build the L1 creation tool |
| `make configure-l1` | Configure nodes for L1 |
| `make destroy` | Tear down infrastructure |

### Primary Network Validators

| Command | Description |
|---------|-------------|
| `make primary-infra CLOUD=aws` | Create Primary Network validator infrastructure (AWS-only) |
| `make primary-deploy CLOUD=aws` | Deploy avalanchego for Primary Network (AWS-only) |
| `make primary-status CLOUD=aws` | Check P/X/C chain sync status (AWS-only) |
| `make backup-keys CLOUD=aws` | Backup staking keys to S3 (AWS-only) |
| `make restore-keys CLOUD=aws` | Restore staking keys from S3 (AWS-only) |
| `make prepare-migration CLOUD=aws` | Prepare new node for migration (supports `SNAPSHOT=true`, AWS-only) |
| `make migrate-validator CLOUD=aws` | Execute validator migration (AWS-only) |

### Database Snapshots

| Command | Description |
|---------|-------------|
| `make create-snapshot` | Create database snapshot from synced node |
| `make restore-snapshot` | Restore database snapshot to a node |
| `make list-snapshots` | List available snapshots in S3 |

### Operations

| Command | Description |
|---------|-------------|
| `make status` | Check node sync status |
| `make health-checks` | Comprehensive health checks |
| `make rolling-restart` | Zero-downtime node restart |
| `make upgrade VERSION=x.y.z` | Upgrade avalanchego version |
| `make reset-l1` | Wipe L1 chain data for redeployment |
| `make logs` | View avalanchego logs |

### Developer Tools

| Command | Description |
|---------|-------------|
| `make monitoring` | Deploy Prometheus + Grafana |
| `make deploy-blockscout` | Deploy block explorer |
| `make faucet` | Deploy token faucet |
| `make graph-node` | Deploy The Graph Node |
| `make erpc` | Deploy eRPC load balancer |

### Validator Manager

| Command | Description |
|---------|-------------|
| `make init-validator-manager` | Build the validator manager initialization tool |
| `make initialize-validator-manager` | Deploy and initialize ValidatorManager contract |

### Testing

| Command | Description |
|---------|-------------|
| `make test-unit` | Run Go unit tests for local tools |
| `make test-e2e-dry` | Run both E2E scripts in dry-run mode (no infra changes) |
| `make test-incremental` | Run lint + validate + unit tests + E2E dry-runs |
| `make test-e2e-l1` | Run full L1 E2E (creates/destroys infra) |
| `make test-e2e-primary` | Run full Primary Network E2E (creates/destroys infra) |

For air-gapped or DNS-restricted environments, you can skip Terraform provider validation with:
`make test-incremental SKIP_TERRAFORM_VALIDATE=true`

## Cloud Provider Options

| Provider | Config | Command |
|----------|--------|---------|
| AWS | `terraform/aws/` | `make infra` (default) |
| GCP | `terraform/gcp/` | `make infra CLOUD=gcp` |
| Azure | `terraform/azure/` | `make infra CLOUD=azure` |

Primary Network validator workflows are currently AWS-only.

## Network Options

```bash
make deploy NETWORK=fuji    # Testnet (default)
make deploy NETWORK=mainnet # Production
```

## Configuration Files

| File | Purpose |
|------|---------|
| `genesis.json` | L1 chain config (chainId, alloc, fees) |
| `validator-chain-config.json` | L1 validator settings (pruning on, fast sync) |
| `rpc-archive-chain-config.json` | Archive RPC settings (no pruning, debug APIs) |
| `rpc-pruned-chain-config.json` | Pruned RPC settings (state-sync, minimal APIs) |
| `primary-network-node-config.json` | Primary Network validator settings |
