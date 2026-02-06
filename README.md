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

**What you get:** validators, RPC nodes, Prometheus/Grafana, and optional add-ons.

- AWS supports dedicated `rpc_archive` + `rpc_pruned` groups.
- GCP and Azure currently use a single `rpc` group (no archive/pruned split).

`l1.env` includes `SUBNET_ID`, `CHAIN_ID`, `CONVERSION_TX`, and (when present in genesis) `EVM_CHAIN_ID`.

[Full L1 Deployment Guide →](docs/L1-DEPLOYMENT.md)

## Primary Network Validator

Deploy high-performance validators for the Avalanche Primary Network:

```bash
make setup && make primary-infra CLOUD=aws && make primary-deploy CLOUD=aws
```

**What you get:** 1x i4i.xlarge primary validator + monitoring + S3 key backup/migration tooling (~$326/mo)

Primary Network workflow targets are AWS-only in this repository.

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

## Testing

```bash
make doctor              # Prereqs + config layout checks
make test-unit           # Go unit tests
make test-e2e-dry        # E2E script dry-runs (no infra changes)
make test-incremental    # lint + validate + unit + e2e dry-run
make test-incremental SKIP_TERRAFORM_VALIDATE=true  # air-gapped/local fallback
make test-e2e-l1         # full L1 E2E (creates/destroys infra)
make test-e2e-primary    # full Primary Network E2E
```

## Documentation

- [L1 Deployment](docs/L1-DEPLOYMENT.md) - Complete L1 setup guide
- [Primary Network](docs/PRIMARY-NETWORK.md) - Validator deployment and migration
- [Operations](docs/OPERATIONS.md) - Upgrades, monitoring, commands reference
- [Add-ons](docs/ADD-ONS.md) - Blockscout, faucet, eRPC, The Graph
- [Genesis Builder](https://build.avax.network/tools/l1-toolbox/create-chain) - Visual genesis generator for `configs/l1/genesis/genesis.json`
- [Troubleshooting](docs/TROUBLESHOOTING.md) - Common issues and solutions

## Prerequisites

```bash
# Required versions:
# - Go 1.24.13+
# - Terraform 1.5+
# - Ansible 2.15+
brew install terraform ansible awscli jq go shellcheck
# Or: make setup
```

## Config Layout

```text
configs/
  l1/
    genesis/
      genesis.json
      genesis-clean.json
    node/
      validator-node-config.json
      rpc-node-config.json
    chain/
      validator-chain-config.json
      rpc-chain-config.json
      rpc-archive-chain-config.json
      rpc-pruned-chain-config.json
  primary-network/
    node/
      primary-network-node-config.json
      primary-validator-node-config.json
```

Use `make validate-config-layout` (or `make doctor`) after editing configs.

## Extending Safely

When adding new services or changing existing behavior:

1. Keep service config under `configs/` instead of adding new root-level files.
2. Add/update a `Makefile` target so workflows stay discoverable.
3. Add dry-run coverage in `tests/e2e-l1.sh` or `tests/e2e-primary-network.sh` when relevant.
4. Run `make test-incremental` before pushing.

## Cloud Providers

```bash
make infra              # AWS (default)
make infra CLOUD=gcp    # Google Cloud
make infra CLOUD=azure  # Azure

# Primary Network workflows are AWS-only
make primary-infra CLOUD=aws
make primary-deploy CLOUD=aws
```

Provider topology note:
- `CLOUD=aws` inventories include `rpc_archive` and `rpc_pruned`.
- `CLOUD=gcp|azure` inventories include a single `rpc` group.

## Getting AVAX for Testing

1. Install [Core Wallet](https://core.app/) and switch to Fuji testnet
2. Get test AVAX from the [Builder Hub Faucet](https://build.avax.network/tools/faucet)
3. Cross-chain transfer to P-Chain (Core Wallet → Portfolio → Cross-Chain)

## Links

- [Genesis Builder](https://build.avax.network/tools/l1-toolbox/create-chain) - Generate genesis JSON visually
- [Avalanche Docs](https://docs.avax.network/)
- [Chain List](https://chainlist.org/) - Check chain ID availability
