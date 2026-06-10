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
./scripts/l1/safe/deploy-contracts.sh
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

### Balance not showing / Safe creation fails silently

If the UI loads and you can connect your wallet but your balance doesn't display and Safe creation shows "Error creating the Safe Account", the issue is almost always the **wallet's RPC URL**.

Self-signed SSL certificates (the default) work for browser page navigation but wallets (Core, MetaMask, Rabby) silently reject HTTPS RPC calls to endpoints with untrusted certs.

**Fix:** Configure your wallet's RPC for the chain to use the direct HTTP URL:
```
http://<rpc-node-ip>:9650/ext/bc/<CHAIN_ID>/rpc
```

NOT the HTTPS proxy (`https://<rpc-node-ip>/rpc`).

For production, use a real domain with Let's Encrypt (`safe_use_letsencrypt: true`) to eliminate this issue entirely.

### Transaction stuck on "indexing..." / `trace_block does not exist` / duplicate transfers

Symptoms (all three share one root cause):
- Executing a transaction in the UI hangs at "indexing..." and the pending tx eventually disappears
- Transaction Service indexer logs show `the method trace_block does not exist/is not available`
- `/api/v1/safes/<address>/transfers/` returns the same transfer twice (same `transactionHash`, different `transferId` — one ending in a log index like `...1`, one in a trace address like `...0,0`), and history in the UI shows duplicate/missing entries

Two distinct causes, both addressed by this repo:

1. **Stale trace-based indexing task.** The celery beat schedule was seeded with `index_internal_txs_task`, the **trace-based** indexer. It requires the Parity/OpenEthereum `trace_block` RPC method, which Avalanche EVMs do not expose, so the task fails forever — that's the log spam and the stuck "indexing..." UI. On L2 networks (`ETH_L2_NETWORK=1`, the default here) the SafeL2 events indexer already covers the same data via `eth_getLogs`. Re-running the `deploy-safe` playbook now removes the stale task automatically, or remove it manually:

   ```bash
   docker exec safe-txs-web python manage.py shell -c "
   from django_celery_beat.models import PeriodicTask
   print(PeriodicTask.objects.filter(name='index_internal_txs').delete())
   "
   ```

2. **Upstream Safe→Safe duplicate ([safe-transaction-service#1556](https://github.com/safe-global/safe-transaction-service/issues/1556), open since 2023).** For a native send from one indexed Safe to another, the events indexer creates **two** transfer rows: a simulated sender-side transfer from the `SafeMultiSigTransaction` event (transferId ending in a trace address like `...0,0`) and the receiver's `SafeReceived` event (transferId ending in a log index like `...1`). This reproduces on production Safe deployments on Base/Polygon/Celo too. This repo ships a patched `safe_events_indexer.py` (bind-mounted over the image module, see `roles/safe/files/patches/`) that skips the simulated row when the recipient is an indexed Safe — re-run the `deploy-safe` playbook to apply it.

**Cleaning up duplicates that were already indexed:** delete only the simulated child rows that have an event-indexed twin for the same transaction:

```bash
docker exec safe-txs-web python manage.py shell -c "
from safe_transaction_service.history.models import InternalTx
dupes = [
    tx.pk for tx in InternalTx.objects.filter(trace_address__contains=',', value__gt=0)
    if InternalTx.objects.filter(
        ethereum_tx=tx.ethereum_tx, _from=tx._from, to=tx.to, value=tx.value,
    ).exclude(trace_address__contains=',').exists()
]
print('Deleting', len(dupes), 'duplicated simulated transfers:',
      InternalTx.objects.filter(pk__in=dupes).delete())
"

# Restart so workers pick up the schedule + patch
cd /opt/safe && docker compose up -d
```

Pending signatures and proposed transactions are not affected — they live in separate tables.

### CLOSE_WAIT connections accumulating

`ss -tan state close-wait` (or `/proc/net/tcp` inside the `safe-txs-worker-indexer` container) shows tens to ~100+ sockets in CLOSE_WAIT, all pointing at the avalanchego RPC port (9650).

This is expected behavior, not a misconfiguration or a leak that grows unboundedly. The TXS celery workers create short-lived HTTP sessions against the RPC; avalanchego closes keep-alive connections after its idle timeout (120s), and the worker's abandoned sockets sit in CLOSE_WAIT until Python garbage-collects the session objects. The count climbs quickly after a restart, then plateaus (GC keeps pace with session churn). It does not exhaust file descriptors at normal indexing volume.

Verify it plateaus rather than grows linearly:
```bash
docker exec safe-txs-worker-indexer sh -c 'awk "\$4==\"08\"" /proc/net/tcp | wc -l'
# sample a few times 10+ minutes apart
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
