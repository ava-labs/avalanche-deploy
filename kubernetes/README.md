# Kubernetes Deployment

Kubernetes support in this repo is organized around the same two workflows as the main repo:

1. L1 setup and operation
2. Primary Network validator/RPC deployment

## Choose A Workflow

### Workflow A: L1 Setup (Validators + RPC + L1 Creation)

Use this when you want to run Avalanche L1 nodes on Kubernetes and create/configure your L1 chain.

### Workflow B: Primary Network Nodes (Validators + RPC)

Use this when you want Kubernetes-hosted Primary Network nodes.

## Scope

Kubernetes covers the full deployment lifecycle: node deployment, L1 creation/configuration, add-on services (Blockscout, faucet, eRPC, Graph Node, Safe, ICM Relayer), monitoring, staking key backup, health checks, and L1 reset. Feature parity with the Terraform/Ansible path.

## Prerequisites

- `kubectl` connected to your cluster
- `helm` v3+
- For local testing: `kind` and Docker
- For L1 creation: funded key in platform-cli keystore (recommended) or `AVALANCHE_PRIVATE_KEY` env fallback

## Make Wrappers (From Repo Root)

You can run the Kubernetes workflows via `Makefile` wrappers from the repo root:

```bash
make k8s-help
make k8s-help-l1
make k8s-help-primary
```

## Workflow A: L1 Quick Start

### Option A: Local kind (fastest for testing)

```bash
cd kubernetes

# 1) Create local cluster
./scripts/create-kind-cluster.sh --name=avalanche-l1 --image=kindest/node:v1.34.0 --workers=1

# 2) Deploy L1 validators + RPC
helm upgrade --install l1-validators ./helm/avalanche-validator -f ./helm/avalanche-validator/values-kind.yaml --set network=fuji

helm upgrade --install l1-rpc ./helm/avalanche-rpc -f ./helm/avalanche-rpc/values-kind.yaml --set network=fuji

# 3) Wait for P-Chain sync on validators
./scripts/wait-for-sync.sh --release=l1-validators

# 4) Create L1
# Recommended key flow:
# platform keys import --name l1-deployer
# platform keys default --name l1-deployer
./scripts/create-l1.sh \
  --release=l1-validators \
  --network=fuji \
  --chain-name=mychain \
  --output=l1.env \
  --key-name=l1-deployer

# 5) Configure validators to track the new L1
./scripts/configure-l1.sh --release=l1-validators --env=l1.env

# 6) Check status
./scripts/status.sh --release=l1-validators
```

Note: the first `kind` run pulls the node image and can take several minutes depending on network speed.
If your laptop is resource constrained, start with `--workers=1` and scale up later.
Host port mapping is disabled by default; use `kubectl port-forward` or pass `--map-host-ports` explicitly.

### Option B: Existing cluster (non-kind)

Use the same Helm releases and scripts as above, skipping cluster creation.

## Workflow B: Primary Network Quick Start

```bash
cd kubernetes

# 1) Deploy Primary validators
helm install primary-validators ./helm/primary-network-validator \
  --set primary_validator_replicas=2 \
  --set network=fuji

# 2) Deploy Primary RPC
helm install primary-rpc ./helm/primary-network-rpc \
  --set primary_rpc_replicas=2 \
  --set network=fuji

# 3) Wait for sync (same script, different release)
./scripts/wait-for-sync.sh --release=primary-validators

# 4) Check status
./scripts/status.sh --release=primary-validators
```

## Monitoring

```bash
cd kubernetes
helm install monitoring ./helm/monitoring
```

Access Grafana:

```bash
kubectl port-forward svc/monitoring-grafana 3000:3000
# http://localhost:3000 (admin/admin)
```

## ICM Relayer (Cross-Chain Messaging)

After your L1 is running:

```bash
source l1.env
helm upgrade --install icm-relayer ./helm/icm-relayer \
  --set "l1.subnetId=$SUBNET_ID" \
  --set "l1.blockchainId=$CHAIN_ID" \
  --set "relayerPrivateKey=0x..." \
  --set "network=fuji"

# Or from repo root:
make k8s-icm-relayer SUBNET_ID=$SUBNET_ID CHAIN_ID=$CHAIN_ID RELAYER_KEY=0x...
```

The relayer connects to the `l1-rpc` service by default. Override with `--set avalanchego.serviceName=<svc>`.

## Helm Chart Map

| Purpose | Chart Path | Recommended Release |
|---------|------------|---------------------|
| L1 validators | `helm/avalanche-validator` | `l1-validators` |
| L1 RPC | `helm/avalanche-rpc` | `l1-rpc` |
| Primary validators | `helm/primary-network-validator` | `primary-validators` |
| Primary RPC | `helm/primary-network-rpc` | `primary-rpc` |
| Monitoring | `helm/monitoring` | `monitoring` |
| ICM Relayer | `helm/icm-relayer` | `icm-relayer` |
| eRPC load balancer | `helm/erpc` | `erpc` |
| Token faucet | `helm/faucet` | `faucet` |
| Blockscout explorer | `helm/blockscout` | `blockscout` |
| The Graph Node | `helm/graph-node` | `graph-node` |
| Safe multisig | `helm/safe` | `safe` |
| Staking key backup | `helm/staking-key-backup` | `staking-key-backup` |

## Script Reference

| Script | Purpose |
|--------|---------|
| `scripts/create-kind-cluster.sh` | Create local kind cluster |
| `scripts/wait-for-sync.sh` | Wait for P-Chain sync on a release |
| `scripts/create-l1.sh` | Create L1 from validator pod IPs |
| `scripts/configure-l1.sh` | Apply subnet/chain bootstrap settings |
| `scripts/status.sh` | Report pod sync and L1 readiness |
| `scripts/cleanup.sh` | Remove Helm releases and optional PVC/kind cleanup |
| `scripts/health-checks.sh` | Comprehensive health checks across all nodes |
| `scripts/reset-l1.sh` | Reset L1 chain data for redeployment |
| `scripts/init-validator-manager.sh` | Initialize ValidatorManager contract via port-forward |

## Add-on Services

After your L1 is running, deploy add-on services:

### eRPC (RPC Load Balancer)

```bash
source l1.env
make k8s-erpc CHAIN_ID=$CHAIN_ID EVM_CHAIN_ID=99999

# Or directly:
helm upgrade --install erpc ./helm/erpc \
  --set "l1.chainId=$CHAIN_ID" \
  --set "l1.evmChainId=99999"
```

Auto-discovers RPC upstreams from the `l1-rpc` service. Provides caching, circuit breaking, and failover.

### Faucet

```bash
make k8s-faucet CHAIN_ID=$CHAIN_ID EVM_CHAIN_ID=99999 FAUCET_KEY=0x...

# Or directly:
helm upgrade --install faucet ./helm/faucet \
  --set "l1.chainId=$CHAIN_ID" \
  --set "l1.evmChainId=99999" \
  --set "faucet.privateKey=0x..."
```

### Blockscout (Block Explorer)

```bash
make k8s-blockscout CHAIN_ID=$CHAIN_ID EVM_CHAIN_ID=99999

# Or directly:
helm upgrade --install blockscout ./helm/blockscout \
  --set "l1.chainId=$CHAIN_ID" \
  --set "l1.evmChainId=99999" \
  --set "l1.rpcUrl=http://l1-rpc:9650/ext/bc/$CHAIN_ID/rpc" \
  --set "l1.wsUrl=ws://l1-rpc:9650/ext/bc/$CHAIN_ID/ws"

# Access frontend:
kubectl port-forward svc/blockscout-frontend 3000:3000
```

Includes backend, frontend, PostgreSQL, Redis, and optional smart contract verifier.

### The Graph Node

```bash
make k8s-graph-node CHAIN_ID=$CHAIN_ID NETWORK_NAME=my-l1

# Access GraphQL:
kubectl port-forward svc/graph-node 8000:8000
# http://localhost:8000/subgraphs/name/<subgraph-name>
```

Includes Graph Node, PostgreSQL, and IPFS.

### Safe (Multisig)

```bash
make k8s-safe EVM_CHAIN_ID=99999 CHAIN_ID=$CHAIN_ID

# Access gateway:
kubectl port-forward svc/safe-cgw 3000:3000
```

Deploys Config Service, Transaction Service, Client Gateway, PostgreSQL (x2), Redis, and RabbitMQ. The init job handles DB migrations, contract registration, and Celery periodic task setup.

Note: Safe UI requires a custom Docker image with `NEXT_PUBLIC_*` vars baked in at build time. Set `ui.image.repository` and `ui.image.tag` to deploy a pre-built image.

### ValidatorManager Initialization

```bash
make k8s-init-validator-manager \
  SUBNET_ID=$SUBNET_ID CHAIN_ID=$CHAIN_ID \
  CONVERSION_TX=<tx-hash> PROXY_ADDRESS=0x... EVM_CHAIN_ID=99999
```

Port-forwards to an RPC pod and runs the Go initialization tool.

## Operations

### Health Checks

```bash
make k8s-health-checks                          # All nodes
make k8s-health-checks CHAIN_ID=$CHAIN_ID       # Include L1 chain status
```

Checks pod status, `/ext/health`, P/X/C chain bootstrap, L1 sync, and version consistency.

### Staking Key Backup

```bash
# Deploy daily backup CronJob
make k8s-backup-keys BACKUP_BUCKET=my-bucket BACKUP_PROVIDER=s3

# Or with IRSA/Workload Identity:
helm upgrade --install staking-key-backup ./helm/staking-key-backup \
  --set "storage.bucket=my-bucket" \
  --set "storage.provider=s3" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:aws:iam::123:role/backup-role"
```

### L1 Reset

```bash
make k8s-reset-l1   # Interactive confirmation required
```

Scales down pods, cleans chain data (preserves staking keys), removes L1 config, scales back up.

## Accessing RPC

L1 validator service (default release `l1-validators`):

```bash
kubectl port-forward svc/l1-validators 9650:9650
```

L1 RPC service (default release `l1-rpc`):

```bash
kubectl port-forward svc/l1-rpc 9650:9650
```

Primary RPC service (default release `primary-rpc`):

```bash
kubectl port-forward svc/primary-rpc 9650:9650
```

## Guardrails

Run these before merging Kubernetes changes:

```bash
# Helm chart lint
for chart in avalanche-validator avalanche-rpc primary-network-validator primary-network-rpc \
  monitoring icm-relayer erpc faucet blockscout graph-node safe staking-key-backup; do
  helm lint ./helm/$chart
done

# Script syntax checks
for f in scripts/*.sh; do bash -n "$f"; done
```

## Troubleshooting

Pods pending:

```bash
kubectl describe pod <pod-name>
```

If pods are unscheduled with messages like `Insufficient cpu` or `does not have a host assigned`, use the local kind profiles:

```bash
helm upgrade --install l1-validators ./helm/avalanche-validator -f ./helm/avalanche-validator/values-kind.yaml --set network=fuji
helm upgrade --install l1-rpc ./helm/avalanche-rpc -f ./helm/avalanche-rpc/values-kind.yaml --set network=fuji
```

Node not syncing:

```bash
kubectl logs <pod-name> -f
```

Service lookup:

```bash
kubectl get svc
```

kind fails with `No such container: <cluster>-control-plane`:

This usually means the Docker daemon API is unhealthy (`docker ps` works, but `docker inspect`/`docker logs` fail).

```bash
docker run -d --name docker-api-check alpine:3.20 sleep 30
docker inspect docker-api-check
docker logs docker-api-check
docker rm -f docker-api-check
```

If `inspect` or `logs` fail, restart Docker Desktop and retry `./scripts/create-kind-cluster.sh`.

## Genesis

Use the [Genesis Builder](https://build.avax.network/tools/l1-toolbox/create-chain) or start from:
`../configs/l1/genesis/genesis.json`

## Cleanup

```bash
cd kubernetes
./scripts/cleanup.sh
```

## Links

- [Main README](../README.md)
- [L1 Deployment Guide](../docs/l1/DEPLOYMENT.md)
- [Primary Network Guide](../docs/primary-network/DEPLOYMENT.md)
- [Operations Guide](../docs/OPERATIONS.md)
