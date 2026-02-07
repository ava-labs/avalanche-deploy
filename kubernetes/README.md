# Kubernetes Deployment

Kubernetes support in this repo is organized around the same two workflows as the main repo:

1. L1 setup and operation
2. Primary Network validator/RPC deployment

## Choose A Workflow

### Workflow A: L1 Setup (Validators + RPC + L1 Creation)

Use this when you want to run Avalanche L1 nodes on Kubernetes and create/configure your L1 chain.

### Workflow B: Primary Network Nodes (Validators + RPC)

Use this when you want Kubernetes-hosted Primary Network nodes.

## Scope And Boundaries

- Kubernetes here covers deployment, sync checks, and L1 creation/configuration flow.
- Advanced AWS operational workflows (staking key backup/restore, snapshots, migration) are in the Terraform/Ansible path, not this Kubernetes folder.

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

## Helm Chart Map

| Purpose | Chart Path | Recommended Release |
|---------|------------|---------------------|
| L1 validators | `helm/avalanche-validator` | `l1-validators` |
| L1 RPC | `helm/avalanche-rpc` | `l1-rpc` |
| Primary validators | `helm/primary-network-validator` | `primary-validators` |
| Primary RPC | `helm/primary-network-rpc` | `primary-rpc` |
| Monitoring | `helm/monitoring` | `monitoring` |

## Script Reference

| Script | Purpose |
|--------|---------|
| `scripts/create-kind-cluster.sh` | Create local kind cluster |
| `scripts/wait-for-sync.sh` | Wait for P-Chain sync on a release |
| `scripts/create-l1.sh` | Create L1 from validator pod IPs |
| `scripts/configure-l1.sh` | Apply subnet/chain bootstrap settings |
| `scripts/status.sh` | Report pod sync and L1 readiness |
| `scripts/cleanup.sh` | Remove Helm releases and optional PVC/kind cleanup |

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
helm lint ./helm/avalanche-validator
helm lint ./helm/avalanche-rpc
helm lint ./helm/primary-network-validator
helm lint ./helm/primary-network-rpc
helm lint ./helm/monitoring

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
- [L1 Deployment Guide](../docs/L1-DEPLOYMENT.md)
- [Primary Network Guide](../docs/PRIMARY-NETWORK.md)
- [Operations Guide](../docs/OPERATIONS.md)
