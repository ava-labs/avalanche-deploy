# Avalanche Deploy

Deployment toolkit for Avalanche L1 blockchains on AWS, GCP, or Azure, plus Primary Network validator workflows on AWS.

## L1 Blockchain

Deploy a complete L1 with validators, RPC nodes, monitoring, and Blockscout:

```bash
make setup && make infra && make deploy
make create-l1
./tools/create-l1/create-l1 --network=fuji --validators=<ip,ip,...> --chain-name=<name> --output=l1.env
source l1.env && make configure-l1 SUBNET_ID=$SUBNET_ID CHAIN_ID=$CHAIN_ID
```

**What you get:** 5 validators, archive + pruned RPC, Prometheus/Grafana, Blockscout (~$650/mo)

[Full L1 Deployment Guide →](docs/L1-DEPLOYMENT.md)

## Primary Network Validator

Deploy high-performance validators for the Avalanche Primary Network:

```bash
make setup && make primary-infra && make primary-deploy
```

**What you get:** 1x i4i.xlarge primary validator + monitoring + S3 key backup/migration tooling (~$326/mo)

[Full Primary Network Guide →](docs/PRIMARY-NETWORK.md)

## Features

| L1 Blockchains | Primary Network |
|----------------|-----------------|
| Custom genesis configuration | High-performance NVMe storage |
| ValidatorManager contracts | S3 staking key backup (KMS encrypted) |
| Block explorer (Blockscout) | Database snapshots |
| Token faucet | Near-zero downtime migration |
| Subgraph indexer (The Graph) | Rolling upgrades |
| Load balancer (eRPC) | |
| Zero-downtime upgrades | |

## Quick Reference

```bash
make status              # Check node health
make health-checks       # Comprehensive health report
make upgrade VERSION=x   # Upgrade avalanchego
make rolling-restart     # Zero-downtime restart
make backup-keys         # Backup staking keys to S3
make destroy             # Tear down (stops billing!)
```

## Documentation

- [L1 Deployment](docs/L1-DEPLOYMENT.md) - Complete L1 setup guide
- [Primary Network](docs/PRIMARY-NETWORK.md) - Validator deployment and migration
- [Operations](docs/OPERATIONS.md) - Upgrades, monitoring, commands reference
- [Add-ons](docs/ADD-ONS.md) - Blockscout, faucet, eRPC, The Graph
- [Genesis Builder](https://build.avax.network/tools/l1-toolbox/create-chain) - Visual genesis.json generator
- [Troubleshooting](docs/TROUBLESHOOTING.md) - Common issues and solutions

## Prerequisites

```bash
brew install terraform ansible awscli jq go
# Or: make setup
```

## Cloud Providers

```bash
make infra              # AWS (default)
make infra CLOUD=gcp    # Google Cloud
make infra CLOUD=azure  # Azure
```

## Getting AVAX for Testing

1. Install [Core Wallet](https://core.app/) and switch to Fuji testnet
2. Get test AVAX from the [Builder Hub Faucet](https://build.avax.network/tools/faucet)
3. Cross-chain transfer to P-Chain (Core Wallet → Portfolio → Cross-Chain)

## Links

- [Genesis Builder](https://build.avax.network/tools/l1-toolbox/create-chain) - Generate genesis.json visually
- [Avalanche Docs](https://docs.avax.network/)
- [Chain List](https://chainlist.org/) - Check chain ID availability
