# Operations & Maintenance Guide

Day-2 operations for your Avalanche infrastructure.

For deployment guides, see [L1 Deployment](l1/DEPLOYMENT.md) or [Primary Network](primary-network/DEPLOYMENT.md).
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
