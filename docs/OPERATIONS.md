# Operations & Maintenance Guide

Day-2 operations for your Avalanche infrastructure.

For workflow-first onboarding, start with [WORKFLOWS.md](WORKFLOWS.md).
For command-focused CLI help, use `make help-l1`, `make help-primary`, `make k8s-help`, or `make help-all`.

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
| `make setup` | Install terraform, ansible, aws-cli, jq, go, shellcheck |
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
| `make create-snapshot CLOUD=aws` | Create database snapshot from synced node (AWS-only) |
| `make restore-snapshot CLOUD=aws` | Restore database snapshot to a node (AWS-only) |
| `make list-snapshots CLOUD=aws` | List available snapshots in S3 (AWS-only) |

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
| `make doctor` | Verify local dependencies and config layout |
| `make help-l1` | Show L1-focused command map |
| `make help-primary` | Show Primary Network-focused command map |
| `make k8s-help` | Show Kubernetes wrapper command map |
| `make validate-config-layout` | Verify required config JSON files exist and parse |
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
| `configs/l1/genesis/genesis.json` | L1 chain config (chainId, alloc, fees) |
| `configs/l1/node/validator-node-config.json` | Validator node runtime settings |
| `configs/l1/node/rpc-node-config.json` | RPC node runtime settings |
| `configs/l1/chain/validator-chain-config.json` | L1 validator chain settings (pruning on, fast sync) |
| `configs/l1/chain/rpc-archive-chain-config.json` | Archive RPC chain settings (no pruning, debug APIs) |
| `configs/l1/chain/rpc-pruned-chain-config.json` | Pruned RPC chain settings (state-sync, minimal APIs) |
| `configs/primary-network/node/primary-network-node-config.json` | Primary Network validator settings |
| `configs/primary-network/node/primary-validator-node-config.json` | Primary validator runtime settings (used by playbooks) |
