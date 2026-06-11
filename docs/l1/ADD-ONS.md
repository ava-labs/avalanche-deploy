# L1 Add-ons

Optional components to enhance your L1 blockchain.

> **Note:** The examples below use `EVM_CHAIN_ID=99999` as a placeholder — replace it with the `chainId` from your genesis file (`configs/l1/genesis/genesis.json`). If your `l1.env` includes `EVM_CHAIN_ID`, you can pass `EVM_CHAIN_ID=$EVM_CHAIN_ID` after `source l1.env`.

> **Image versions:** All add-on container images are pinned to specific
> release tags in each role's `defaults/main.yml` — re-running a deploy
> playbook never silently upgrades a running stack. To upgrade, override the
> image/tag variable (or bump the default) and re-run; add `-e force_pull=true`
> only if a pinned tag was re-published upstream.

## Blockscout (Block Explorer)

Deploy a block explorer for your L1:

```bash
source l1.env
make deploy-blockscout CHAIN_ID=$CHAIN_ID EVM_CHAIN_ID=99999 CHAIN_NAME="My L1"
```

Access: `http://<archive-rpc-ip>:4001`

> **Note:** Blockscout is deployed to the first `rpc_archive` host when available; otherwise it falls back to the first `rpc` host.

## Faucet (Token Distribution)

Deploy a faucet for developers to request test tokens:

```bash
source l1.env
make faucet CHAIN_ID=$CHAIN_ID EVM_CHAIN_ID=99999 FAUCET_KEY=0x...
```

Access: `http://<rpc-ip>:8010`

> **Note:** The faucet wallet must be funded on your L1.

> **Warning:** There is no published official image for
> [ava-labs/avalanche-faucet](https://github.com/ava-labs/avalanche-faucet) —
> the default `avaplatform/faucet` reference does not exist on Docker Hub.
> Build and push your own image and set `-e faucet_image=<repo> -e faucet_image_tag=<version>`.

## The Graph Node (Subgraph Indexing)

Deploy The Graph for indexing blockchain data via GraphQL:

```bash
source l1.env
make graph-node CHAIN_ID=$CHAIN_ID NETWORK_NAME=my-l1
```

Endpoints:
- GraphQL: `http://<rpc-ip>:8000/subgraphs/name/<SUBGRAPH>`
- Admin: `http://<rpc-ip>:8020`

### Deploying a Subgraph

1. Create your subgraph project:
   ```bash
   graph init --product hosted-service <SUBGRAPH_NAME>
   ```

2. Update `subgraph.yaml` with your L1 network:
   ```yaml
   network: my-l1
   source:
     address: "<CONTRACT_ADDRESS>"
     startBlock: 0
   ```

3. Generate types and build:
   ```bash
   graph codegen && graph build
   ```

4. Create and deploy:
   ```bash
   graph create --node http://<rpc-ip>:8020 <SUBGRAPH_NAME>
   graph deploy --node http://<rpc-ip>:8020 \
     --ipfs http://<rpc-ip>:5001 \
     <SUBGRAPH_NAME>
   ```

## eRPC (Load Balancer)

> **Included by default.** eRPC is automatically deployed as part of `make configure-l1`. The EVM chain ID is auto-detected from `configs/l1/genesis/genesis.json`. Skip with `SKIP_ERPC=true`.

To re-deploy or reconfigure eRPC standalone:

```bash
source l1.env
make erpc CHAIN_ID=$CHAIN_ID EVM_CHAIN_ID=99999
```

RPC endpoint: `http://<monitoring-ip>:4000`

### Features

- **Intelligent routing**: `debug_*` and `trace_*` methods route to archive nodes only
- **Load balancing** across all RPC nodes
- **Automatic failover** with circuit breaker
- **Response caching**
- **Prometheus metrics**

### Usage

Instead of connecting directly to RPC nodes, use eRPC:

```bash
# Direct RPC (don't use in production):
curl http://rpc-node:9650/ext/bc/$CHAIN_ID/rpc

# Through eRPC (recommended):
curl -X POST http://<monitoring-ip>:4000 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

In your dApp:
```javascript
const RPC_URL = "http://<monitoring-ip>:4000"
```

## ICM Relayer (Cross-Chain Messaging)

Deploy the ICM Relayer for Avalanche Interchain Messaging between your L1 and C-Chain:

```bash
source l1.env
make icm-relayer SUBNET_ID=$SUBNET_ID CHAIN_ID=$CHAIN_ID RELAYER_KEY=0x...
```

Endpoints:
- API: `http://<rpc-ip>:8080`
- Health: `http://<rpc-ip>:8080/health`
- Metrics: `http://<rpc-ip>:9090/metrics`

### What It Does

The ICM Relayer listens for Avalanche Warp Messages on source blockchains, aggregates BLS signatures from validators, and delivers cross-chain messages to destination blockchains. By default it relays bidirectionally between your L1 and C-Chain.

### Prerequisites

- The `RELAYER_KEY` wallet must be funded on **both** chains:
  - C-Chain: Fund with AVAX for gas
  - L1 Chain: Fund with native token for gas
- Use a dedicated relay wallet (not your main deployer key)

### Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `SUBNET_ID` | (required) | Subnet ID from create-l1 output |
| `CHAIN_ID` | (required) | Blockchain ID from create-l1 output |
| `RELAYER_KEY` | (required) | Hex private key for relay transactions |
| `NETWORK` | fuji | Network name (fuji or mainnet) |

### Kubernetes

```bash
make k8s-icm-relayer SUBNET_ID=$SUBNET_ID CHAIN_ID=$CHAIN_ID RELAYER_KEY=0x...
```

## Safe Multisig

See [SAFE.md](SAFE.md) for deploying Gnosis Safe infrastructure.

```bash
# Deploy Safe contracts + infrastructure (auto-detects chain from l1.env)
make safe
```

Requires the Singleton Factory (`0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7`) in your genesis alloc.
