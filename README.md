# Avalanche Deploy

Production infrastructure automation for Avalanche blockchains.

## Two Paths

| | **Launch an Avalanche L1** | **Run Primary Network Validators** |
|---|---|---|
| **What** | Deploy your own L1 blockchain with validators, RPC nodes, and a full service stack | Operate production Avalanche Primary Network validators |
| **Features** | Validators, archive + pruned RPC, eRPC load balancer (built-in), monitoring, block explorer, faucet, The Graph, ICM Relayer, Safe | Validators, staking key backup, database snapshots, near-zero-downtime migration, monitoring |
| **Clouds** | AWS, GCP, Azure | AWS |
| **Guide** | [L1 Deployment](docs/l1/DEPLOYMENT.md) | [Primary Network](docs/primary-network/DEPLOYMENT.md) |

Both paths support deployment via **Terraform + Ansible** (cloud VMs) or **[Kubernetes](kubernetes/README.md)** (existing clusters).

## Prerequisites

Install Terraform, Ansible, AWS CLI, Go, jq, and shellcheck — or run `make setup`.

## Getting Started

1. **L1 blockchain** — follow the [L1 Deployment Guide](docs/l1/DEPLOYMENT.md)
2. **Primary Network validators** — follow the [Primary Network Guide](docs/primary-network/DEPLOYMENT.md)

## Repo Layout

```text
configs/      Runtime config and genesis files (L1 + Primary Network)
terraform/    Provider infrastructure roots (l1/ and primary-network/)
ansible/      Deployment and operations playbooks/roles
scripts/      Operator helper scripts (l1/ and primary-network/)
tools/        Go CLIs (create-l1, initialize-validator-manager)
tests/        E2E and dry-run tests
kubernetes/   Kubernetes deployment path (Helm-based)
docs/         Guides and reference docs
```

## Documentation

- [L1 Deployment](docs/l1/DEPLOYMENT.md) — Full L1 runbook
- [Primary Network](docs/primary-network/DEPLOYMENT.md) — Validator deployment, snapshots, migration
- [Add-ons](docs/l1/ADD-ONS.md) — Blockscout, faucet, eRPC, The Graph, ICM Relayer, Safe
- [Operations](docs/OPERATIONS.md) — Upgrades, health checks, monitoring, rolling restarts
- [Troubleshooting](docs/TROUBLESHOOTING.md) — Common issues and fixes
- [Kubernetes](kubernetes/README.md) — Helm-based deployment alternative
- [Security](SECURITY.md) — Security expectations and guidelines

## Command Help

```bash
make help          # Overview
make help-l1       # L1 commands
make help-primary  # Primary Network commands
make k8s-help      # Kubernetes commands
make help-all      # Everything
```
