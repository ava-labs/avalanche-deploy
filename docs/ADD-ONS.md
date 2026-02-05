# L1 Add-ons

Optional components to enhance your L1 blockchain.

## Blockscout (Block Explorer)

Deploy a block explorer for your L1:

```bash
source l1.env
make deploy-blockscout CHAIN_ID=$CHAIN_ID EVM_CHAIN_ID=99999 CHAIN_NAME="My L1"
```

Access: `http://<archive-rpc-ip>:4001`

> **Note:** Blockscout is deployed on the archive RPC node which has full history and debug APIs.

## Faucet (Token Distribution)

Deploy a faucet for developers to request test tokens:

```bash
source l1.env
make faucet CHAIN_ID=$CHAIN_ID EVM_CHAIN_ID=99999 FAUCET_KEY=0x...
```

Access: `http://<rpc-ip>:8000`

> **Note:** The faucet wallet must be funded on your L1.

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

Deploy eRPC for RPC load balancing, caching, and automatic failover:

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

## Safe Multisig (Experimental)

> **Warning:** Safe Multisig support is experimental and not production-ready. Known issues include transaction indexing delays, Docker container restarts, and HTTPS certificate management.

See [SAFE.md](SAFE.md) for deploying Gnosis Safe infrastructure.

```bash
# Merge Safe contracts into genesis (before L1 creation)
make safe-genesis

# Deploy Safe infrastructure (after L1 is running)
make safe CHAIN_ID=$CHAIN_ID EVM_CHAIN_ID=99999

# Reset genesis to remove Safe contracts
make reset-genesis
```
