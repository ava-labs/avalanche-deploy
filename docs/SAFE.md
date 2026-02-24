# Safe Multisig Infrastructure

This guide explains how to deploy Safe (formerly Gnosis Safe) multisig infrastructure on your Avalanche L1.

## Overview

Safe is a smart contract wallet that requires multiple signatures to execute transactions. This deployment includes:

- **Safe Wallet Web UI** - User interface for creating and managing Safes
- **Transaction Service** - Backend API for collecting signatures and indexing transactions (3 specialized Celery workers)
- **Config Service** - Chain configuration and metadata
- **Client Gateway (Nest)** - API aggregation layer for the web UI
- **PostgreSQL, Redis, RabbitMQ** - Supporting infrastructure

Contracts are deployed at runtime via the Singleton Factory (`0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7`), matching how Safe works on every other EVM chain.

## Prerequisites

1. Deployed Avalanche L1 with RPC node running
2. Singleton Factory deployed at `0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7` (include in genesis alloc)
3. Ansible inventory with `rpc` host group
4. `AVALANCHE_PRIVATE_KEY` set (for contract deployment)

## Quick Start

```bash
# Single command - deploys contracts + full backend stack
make safe
```

That's it. The `safe` target:
1. Auto-detects `CHAIN_ID` and `EVM_CHAIN_ID` from `l1.env`
2. Deploys 8 Safe v1.4.1 contracts via Singleton Factory (if `AVALANCHE_PRIVATE_KEY` is set)
3. Runs the Ansible playbook to set up the full backend + UI

You can also pass chain IDs explicitly:
```bash
make safe CHAIN_ID=xxx EVM_CHAIN_ID=yyy
```

### Contract Addresses

All 8 contracts deploy to canonical CREATE2 addresses (identical to mainnet Ethereum):

| Contract | Address |
|----------|---------|
| Safe L2 Singleton | `0x29fcB43b46531BcA003ddC8FCB67FFE91900C762` |
| SafeProxyFactory | `0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67` |
| MultiSend | `0x38869bf66a61cF6bDB996A6aE40D5853Fd43B526` |
| MultiSendCallOnly | `0x9641d764fc13c8B624c04430C7356C1C7C8102e2` |
| CompatibilityFallbackHandler | `0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99` |
| CreateCall | `0x9b35Af71d77eaf8d7e40252370304687390A1A52` |
| SignMessageLib | `0xd53cd0aB83D845Ac265BE939c57F53AD838012c9` |
| SimulateTxAccessor | `0x3d4BA2E0884aa488718476ca2FB8Efc291A46199` |

### Deploy Contracts Separately

If you need to deploy contracts independently (e.g., from a different machine):

```bash
RPC_URL=http://<node-ip>:9650/ext/bc/<chain-id>/rpc \
PRIVATE_KEY=0x... \
./scripts/safe/deploy-contracts.sh
```

The script is idempotent - it skips contracts that are already deployed.

## Architecture

```
┌─────────────────── RPC Node ───────────────────┐
│                                                │
│  Nginx (:8080 -> :443, :4443)                  │
│    ├── /        → Safe Wallet Web UI           │
│    ├── /cgw/*   → Client Gateway (Nest)        │
│    ├── /txs/*   → Transaction Service          │
│    ├── /cfg/*   → Config Service               │
│    ├── /rpc     → Avalanche RPC proxy          │
│    └── :4443    → Blockscout Block Explorer    │
│                                                │
│  Docker Compose (14 containers)                │
│    - 3x PostgreSQL (txs, cfg, cgw)             │
│    - Redis, RabbitMQ                           │
│    - TXS Web + 3 Workers + Scheduler           │
│    - Config Service, Client Gateway (Nest)     │
│    - Safe Wallet Web UI                        │
│                                                │
│  AvalancheGo (:9650)                           │
│    └── L1 RPC with Safe contracts              │
└────────────────────────────────────────────────┘
```

## Accessing Safe

After deployment, access the Safe UI via **HTTPS** (required for wallet connections):

```
https://<rpc-node-ip>/
```

### SSL Options

**Option 1: Self-signed certificate (default)**

A self-signed SSL certificate is auto-generated. Accept the browser security warning to proceed.

**Option 2: Let's Encrypt (recommended for production)**

```bash
make safe -e "safe_use_letsencrypt=true" \
  -e "safe_domain=safe.yourdomain.com" \
  -e "safe_letsencrypt_email=admin@yourdomain.com"
```

### API Endpoints

| Service | URL |
|---------|-----|
| Web UI | `https://<ip>/` |
| Block Explorer | `https://<ip>:4443/` |
| Transaction Service API | `https://<ip>/txs/api/v1/` |
| Config Service API | `https://<ip>/cfg/api/v1/` |
| Client Gateway | `https://<ip>/cgw/` |
| RPC (via HTTPS proxy) | `https://<ip>/rpc` |

### Health Checks

```bash
# Transaction Service
curl -k https://<ip>/txs/api/v1/about/

# Config Service
curl -k https://<ip>/cfg/api/v1/about/

# Client Gateway
curl -k https://<ip>/cgw/about
```

## Troubleshooting

### Services won't start

```bash
ssh <rpc-node>
cd /opt/safe
docker compose logs -f
```

### Check service health

```bash
systemctl status safe
docker ps --format "table {{.Names}}\t{{.Status}}"
```

### Database issues

Reset databases (WARNING: destroys all Safe data):
```bash
cd /opt/safe
docker compose down -v
rm -rf /opt/safe/data/postgres-*
docker compose up -d
```

## Configuration

### Default Ports

| Service | Port |
|---------|------|
| Nginx HTTP redirect | 8080 |
| Nginx HTTPS | 443 |
| Blockscout HTTPS | 4443 |
| Transaction Service | 8001 |
| Config Service | 8002 |
| Client Gateway | 8003 |
| Web UI | 3000 |

### Customization

Override defaults via `-e` flags:

```bash
make safe EVM_CHAIN_ID=99999 \
  -e "safe_http_port=8888" \
  -e "safe_chain_name=My Custom L1"
```

## Security Considerations

1. **Firewall**: Only expose ports 80/443/4443 to the internet
2. **HTTPS**: Self-signed cert for testing, Let's Encrypt for production
3. **Secrets**: Auto-generated and stored in `/opt/safe/` (`.db_password`, `.rabbitmq_password`, etc.)
4. **Security Headers**: nginx configured with HSTS, X-Frame-Options, X-Content-Type-Options
5. **RPC access**: Transaction Service connects to local RPC via `host.docker.internal`
