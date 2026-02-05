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
| `make setup` | Install terraform, ansible, jq |
| `make infra` | Create L1 cloud infrastructure |
| `make deploy` | Install avalanchego on L1 nodes |
| `make create-l1` | Build the L1 creation tool |
| `make configure-l1` | Configure nodes for L1 |
| `make destroy` | Tear down infrastructure |

### Primary Network Validators

| Command | Description |
|---------|-------------|
| `make primary-infra` | Create Primary Network validator infrastructure |
| `make primary-deploy` | Deploy avalanchego for Primary Network |
| `make primary-status` | Check P/X/C chain sync status |
| `make backup-keys` | Backup staking keys to S3 |
| `make restore-keys` | Restore staking keys from S3 |
| `make prepare-migration` | Prepare new node for migration (supports `SNAPSHOT=true`) |
| `make migrate-validator` | Execute validator migration |

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

## Cloud Provider Options

| Provider | Config | Command |
|----------|--------|---------|
| AWS | `terraform/aws/` | `make infra` (default) |
| GCP | `terraform/gcp/` | `make infra CLOUD=gcp` |
| Azure | `terraform/azure/` | `make infra CLOUD=azure` |

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
