# Safe Multisig Infrastructure

This guide explains how to deploy Safe (formerly Gnosis Safe) multisig infrastructure on your Avalanche L1.

## Overview

Safe is a smart contract wallet that requires multiple signatures to execute transactions. This deployment includes:

- **Safe Wallet Web UI** - User interface for creating and managing Safes
- **Transaction Service** - Backend API for collecting signatures and indexing transactions
- **Config Service** - Chain configuration and metadata
- **Client Gateway** - API aggregation layer for the web UI
- **PostgreSQL, Redis, RabbitMQ** - Supporting infrastructure

## Prerequisites

1. Deployed Avalanche L1 with RPC node running
2. Genesis file configured with Safe contracts (see below)
3. Ansible inventory with `rpc` host group

## Quick Start

### Step 1: Add Safe Contracts to Genesis

Before creating your L1, merge Safe contracts into your genesis file:

```bash
make safe-genesis
```

This adds 8 Safe v1.4.1 contracts at canonical CREATE2 addresses:

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

### Step 2: Create Your L1

```bash
make create-l1
source l1.env  # Sets SUBNET_ID and CHAIN_ID
```

### Step 3: Deploy Safe Infrastructure

```bash
make safe CHAIN_ID=$CHAIN_ID EVM_CHAIN_ID=<your-evm-chain-id>
```

The EVM chain ID should match the `chainId` field in your `genesis.json`.

## Architecture

```
┌─────────────────── RPC Node ───────────────────┐
│                                                │
│  Nginx (:8080)                                 │
│    ├── /        → Safe Wallet Web UI           │
│    ├── /cgw/*   → Client Gateway               │
│    ├── /txs/*   → Transaction Service          │
│    └── /cfg/*   → Config Service               │
│                                                │
│  Docker Compose (12 containers)                │
│    - 3x PostgreSQL (txs, cfg, cgw)             │
│    - Redis, RabbitMQ                           │
│    - TXS Web + Worker + Scheduler              │
│    - Config Service, Client Gateway            │
│    - Safe Wallet Web UI                        │
│                                                │
│  AvalancheGo (:9650)                           │
│    └── L1 RPC with pre-deployed Safe contracts │
└────────────────────────────────────────────────┘
```

## Accessing Safe

After deployment, access the Safe UI at:

```
http://<rpc-node-ip>:8080/
```

### API Endpoints

| Service | URL |
|---------|-----|
| Web UI | `http://<ip>:8080/` |
| Transaction Service API | `http://<ip>:8080/txs/api/v1/` |
| Config Service API | `http://<ip>:8080/cfg/api/v1/` |
| Client Gateway | `http://<ip>:8080/cgw/` |

### Health Checks

```bash
# Transaction Service
curl http://<ip>:8080/txs/api/v1/about/

# Config Service
curl http://<ip>:8080/cfg/api/v1/about/

# Client Gateway
curl http://<ip>:8080/cgw/health
```

## Creating a Safe

1. Open `http://<rpc-node-ip>:8080/` in your browser
2. Connect your wallet (MetaMask, WalletConnect, etc.)
3. Click "Create new Safe"
4. Add owner addresses and set threshold
5. Review and deploy

## Configuration

### Default Ports

| Service | Port |
|---------|------|
| Nginx (external) | 8080 |
| Transaction Service | 8001 |
| Config Service | 8002 |
| Client Gateway | 8003 |
| Web UI | 3000 |

### Customization

Override defaults in your playbook or via `-e` flags:

```bash
ansible-playbook playbooks/05-deploy-safe.yml \
  -e "chain_id=$CHAIN_ID" \
  -e "evm_chain_id=99999" \
  -e "safe_http_port=8888" \
  -e "chain_name=My Custom L1"
```

### Environment Variables

Key configuration files:
- `txs.env` - Transaction Service (Django)
- `cfg.env` - Config Service (Django)
- `cgw.env` - Client Gateway (Node.js)
- `ui.env` - Web UI (Next.js)

## Troubleshooting

### Services won't start

Check Docker logs:
```bash
ssh <rpc-node>
cd /opt/safe
docker-compose logs -f
```

### Transaction Service can't connect to RPC

Verify avalanchego is running and the RPC is accessible:
```bash
curl -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
  http://localhost:9650/ext/bc/<CHAIN_ID>/rpc
```

### Database issues

Reset databases (WARNING: destroys all Safe data):
```bash
cd /opt/safe
docker-compose down -v
rm -rf /opt/safe/data/postgres-*
docker-compose up -d
```

### Check service health

```bash
systemctl status safe
docker ps --format "table {{.Names}}\t{{.Status}}"
```

## Maintenance

### Restart services

```bash
systemctl restart safe
```

### View logs

```bash
# All services
cd /opt/safe && docker-compose logs -f

# Specific service
docker logs -f safe-txs-web
```

### Update versions

Edit `/opt/safe/docker-compose.yml` and change image tags, then:
```bash
cd /opt/safe
docker-compose pull
docker-compose up -d
```

## Security Considerations

1. **Firewall**: Only expose port 8080 to trusted networks
2. **HTTPS**: Use a reverse proxy (nginx, Caddy) with SSL in production
3. **Database passwords**: Auto-generated and stored in `/opt/safe/.db_password`
4. **RPC access**: Transaction Service connects to local RPC via `host.docker.internal`

## Contract Addresses

These canonical Safe v1.4.1 addresses are identical to mainnet Ethereum and other EVM chains, ensuring wallet compatibility:

```
Safe L2 v1.4.1:           0x29fcB43b46531BcA003ddC8FCB67FFE91900C762
SafeProxyFactory v1.4.1:  0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67
MultiSend v1.4.1:         0x38869bf66a61cF6bDB996A6aE40D5853Fd43B526
MultiSendCallOnly v1.4.1: 0x9641d764fc13c8B624c04430C7356C1C7C8102e2
FallbackHandler v1.4.1:   0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99
CreateCall v1.4.1:        0x9b35Af71d77eaf8d7e40252370304687390A1A52
SignMessageLib v1.4.1:    0xd53cd0aB83D845Ac265BE939c57F53AD838012c9
SimulateTxAccessor v1.4.1:0x3d4BA2E0884aa488718476ca2FB8Efc291A46199
```
