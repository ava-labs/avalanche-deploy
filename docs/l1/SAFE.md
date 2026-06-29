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

> **Note:** `make safe` does not forward `-e` flags (GNU make consumes `-e` itself). To override Ansible variables, run the playbook directly:

```bash
cd ansible
ansible-playbook -i inventory/aws_hosts playbooks/l1/deploy-safe.yml \
  -e chain_id=<CHAIN_ID> \
  -e evm_chain_id=<EVM_CHAIN_ID> \
  -e safe_use_letsencrypt=true \
  -e safe_domain=safe.yourdomain.com \
  -e safe_letsencrypt_email=admin@yourdomain.com
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

## Operating L1 Contracts from the Safe (PoAManager)

A common use of the Safe is to own your L1's **PoAManager**, so validator-set changes
(add/remove a validator, update weight) require multisig approval. Compose these via
**Apps → Transaction Builder**.

**The Safe must be the owner of the PoAManager.** `initiateValidatorRegistration`,
`initiateValidatorRemoval`, and `initiateValidatorWeightUpdate` are `onlyOwner`. After
`initialize-validator-manager` runs, the PoAManager owner is the **deployer EOA**, not the Safe.
Once the Safe is deployed, transfer ownership to it from that EOA:

```bash
# from the current PoAManager owner (the deployer EOA)
cast send <POA_MANAGER> "transferOwnership(address)" <SAFE_ADDRESS> \
  --private-key <CURRENT_OWNER_KEY> \
  --rpc-url http://<rpc-ip>:9650/ext/bc/<CHAIN_ID>/rpc
cast call <POA_MANAGER> "owner()(address)" --rpc-url <...>   # must equal <SAFE_ADDRESS>
```

Then in the Transaction Builder, target the PoAManager (e.g.
`initiateValidatorWeightUpdate(bytes32 validationID, uint64 newWeight)`), collect signatures, and
execute.

> The PoAManager owns the ValidatorManager proxy (`0xfacade…`) — the Safe owns the PoAManager.
> To move the ValidatorManager's ownership later, the Safe (as PoAManager owner) calls
> `PoAManager.transferValidatorManagerOwnership(address)`.

## Troubleshooting

### Transaction Builder execute fails with `GS013` / "cannot estimate gas" / "most likely fail"

`GS013` is the Safe singleton re-throwing a **reverted inner call**: `execTransaction` reverts
when the inner call fails and `safeTxGas`/`gasPrice` are both 0. For PoAManager calls the usual
cause is that **the Safe is not the PoAManager owner** — the `onlyOwner` check reverts
`OwnableUnauthorizedAccount`, which the Safe surfaces as the opaque `GS013` (and the UI's gas
estimation of `execTransaction` reverts → "most likely fail / missing revert data").

Fix: transfer PoAManager ownership to the Safe (see *Operating L1 Contracts from the Safe*).
Confirm before signing — this reproduces the exact inner call the Safe makes (`msg.sender` = Safe):

```bash
# Reverts 0x118cdaa7 (OwnableUnauthorizedAccount) if the Safe is not the owner; succeeds once it is.
cast call <POA_MANAGER> "initiateValidatorWeightUpdate(bytes32,uint64)" <VALIDATION_ID> <NEW_WEIGHT> \
  --from <SAFE_ADDRESS> --rpc-url http://<rpc-ip>:9650/ext/bc/<CHAIN_ID>/rpc
```

Other inner-call reverts that also surface as `GS013`: `InvalidValidatorStatus` (wrong/stale
`validationID`, or the validator isn't `Active`) and `MaxChurnRateExceeded` (weight change beyond
the churn limit).

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

### Transaction stuck on "indexing..." / shows "Canceled" / `trace_block does not exist` / duplicate transfers

Symptoms (all share one root cause):
- Executing a transaction in the UI hangs at "indexing..." and the pending tx eventually disappears
- After execution, clicking "View Transaction" shows the transaction as **Canceled** (even though it confirmed on-chain)
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

### Executed transactions show "Canceled" in the UI

Symptom: you execute a multisig transaction, it confirms on-chain (the Safe nonce
advances), but the Safe Wallet shows it as **Canceled** — often seen right after
clicking "View Transaction" during the indexing step, and on freshly-created Safes
it can stick permanently.

This is **not** a separate bug from the trace-indexer issue above — it is the *visible
symptom* of the Safe's execution history never being indexed into `SafeLastStatus`.
The mechanism is exact (verified against TXS v5.40.1 + CGW v1.96.0):

- The Client Gateway labels a transaction **Cancelled** when, and only when,
  `isExecuted == false` **and** `safe.nonce > transaction.nonce`
  (`multisig-transaction-status.mapper.ts`).
- `isExecuted` is set when the indexer links the on-chain execution to the proposed
  transaction by matching `safe_tx_hash`. On L2 networks that linkage is done by the
  **events** indexer (`index_safe_events_task`) decoding `SafeMultiSigTransaction`
  events — never by the trace indexer.
- `safe.nonce` comes from the indexed `SafeLastStatus`, but TXS **falls back to the
  live on-chain nonce when `SafeLastStatus.nonce == 0`** (`safe_service.get_safe_info`).

So if the Safe's executions were never indexed (because the trace indexer was the
only execution indexer and it failed forever on Avalanche), `SafeLastStatus` is never
built → `safe.nonce` is always the live, already-advanced nonce while `isExecuted`
stays `false` → **every executed transaction shows Cancelled, permanently.**

Switching to event-only indexing (above) fixes this **going forward**, but it does
**not** reprocess history — Safes indexed under the old config keep showing Cancelled
until their execution history is rebuilt. Re-running `deploy-safe` now does this
automatically (it reindexes + reprocesses whenever it removes the stale trace task).
To repair manually:

```bash
# 1. Re-fetch the Safe's events from its creation block (events-mode reindex)
docker exec safe-txs-web python manage.py reindex_master_copies \
  --addresses <SAFE_ADDRESS> --block-process-limit 500

# 2. Rebuild SafeLastStatus and re-link executions to proposed transactions.
#    This is what flips already-"Cancelled" transactions to Success.
docker exec safe-txs-web python manage.py process_txs_again --sync

# 3. Restart so workers pick up the rebuilt state
cd /opt/safe && docker compose up -d
```

After this, `safe.nonce` is served from the rebuilt `SafeLastStatus` (consistent with
`isExecuted`), and transactions that actually executed render as Success.

> If `reindex_master_copies` finds no events for the Safe at all, confirm TXS is
> connected to the **L1's** RPC (`/ext/bc/<CHAIN_ID>/rpc`), not the C-Chain — a chainId
> mismatch makes the indexer compute a different `safe_tx_hash` than the proposer, which
> also breaks linkage. Verify with `manage.py check_chainid_matches`.

### CLOSE_WAIT connections accumulating

`ss -tan state close-wait` (or `/proc/net/tcp` inside the `safe-txs-worker-indexer` container) shows tens to ~100+ sockets in CLOSE_WAIT, all pointing at the avalanchego RPC port (9650).

This is expected behavior, not a misconfiguration or an unbounded leak. The TXS worker runs celery with `--pool=gevent --concurrency=5000`, and safe-eth-py's `EthereumClient` uses a requests session with `pool_maxsize=100, pool_block=False`. Concurrency bursts fill the (LIFO) urllib3 pool with connections; the deep slots then sit idle, avalanchego closes them after its 120s HTTP idle timeout, and the half-closed sockets stay in CLOSE_WAIT *inside the pool* until that slot is ever checked out again.

The count is therefore bounded at roughly `100 × <number of EthereumClient instances in the worker>` — in practice it saturates around ~250 (measured: 37 → 95 → 140 → 194 → 228 → 234 over 30 minutes after a restart, then flat). A few hundred sockets is harmless against the container's file-descriptor limit.

Verify it saturates rather than grows linearly:
```bash
docker exec safe-txs-worker-indexer sh -c 'awk "\$4==\"08\"" /proc/net/tcp | wc -l'
# sample a few times 10+ minutes apart; expect it to level off in the low hundreds
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

Override defaults by running the playbook directly with `-e` flags (`make safe` does not forward `-e` — GNU make consumes it):

```bash
cd ansible
ansible-playbook -i inventory/aws_hosts playbooks/l1/deploy-safe.yml \
  -e chain_id=<CHAIN_ID> \
  -e evm_chain_id=99999 \
  -e safe_http_port=8888 \
  -e 'safe_chain_name="My Custom L1"'
```

> Replace `99999` with the `chainId` from your genesis file (`configs/l1/genesis/genesis.json`).

## Security Considerations

1. **Firewall**: Only expose ports 80/443/4443 to the internet
2. **HTTPS**: Self-signed cert for testing, Let's Encrypt for production
3. **Secrets**: Auto-generated and stored in `/opt/safe/` (`.db_password`, `.rabbitmq_password`, etc.)
4. **Security Headers**: nginx configured with HSTS, X-Frame-Options, X-Content-Type-Options
5. **RPC access**: Transaction Service connects to local RPC via `host.docker.internal`
