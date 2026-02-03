# Avalanche L1 Deploy

Deploy production-ready Avalanche L1 blockchains on AWS, GCP, or Azure.

```bash
make setup      # install tools (terraform, ansible, jq)
make infra      # create cloud VMs
make deploy     # install avalanchego
make create-l1  # create your L1 blockchain
make status     # check node health
make destroy    # tear down (stops billing!)
```

## What You Get

| Component | Default | Purpose |
|-----------|---------|---------|
| **Validators** | 2 | Block production, consensus |
| **RPC Node** | 1 | External queries, block explorer |
| **Monitoring** | 1 | Prometheus + Grafana dashboards |

**Optional Add-ons:**
- **Blockscout** - Block explorer for your L1
- **Safe Multisig** `[EXPERIMENTAL]` - Gnosis Safe infrastructure (see [SAFE.md](SAFE.md))

> **Warning:** Safe Multisig support is experimental and not production-ready. Known issues include transaction indexing delays, Docker container restarts, and HTTPS certificate management. Use at your own risk.

## Architecture

```mermaid
flowchart TB
    subgraph Internet
        Users([Users / dApps])
        PrimaryNetwork([Avalanche Primary Network])
    end

    subgraph VPC["AWS VPC (10.0.0.0/16)"]
        subgraph ValidatorsSG["validators-sg"]
            V1[Validator 1<br/>avalanchego<br/>:9651 P2P]
            V2[Validator 2<br/>avalanchego<br/>:9651 P2P]
        end

        subgraph RPCSG["rpc-sg"]
            RPC[RPC Node<br/>avalanchego<br/>:9650 API]
            Blockscout[Blockscout<br/>:4001 Explorer]
        end

        subgraph MonitoringSG["monitoring-sg"]
            Prometheus[Prometheus<br/>:9090]
            Grafana[Grafana<br/>:3000]
        end
    end

    PrimaryNetwork <-->|P2P :9651| V1
    PrimaryNetwork <-->|P2P :9651| V2
    PrimaryNetwork <-->|P2P :9651| RPC

    V1 <-->|P2P :9651| V2
    V1 <-->|P2P :9651| RPC
    V2 <-->|P2P :9651| RPC

    Users -->|RPC :9650| RPC
    Users -->|Explorer :4001| Blockscout
    Users -->|Dashboard :3000| Grafana

    Blockscout -.->|queries| RPC

    V1 -.->|metrics :9650/:9100| Prometheus
    V2 -.->|metrics :9650/:9100| Prometheus
    RPC -.->|metrics :9650/:9100| Prometheus
    Prometheus -.-> Grafana
```

**4 EC2 Instances:**
| Instance | Security Group | Purpose |
|----------|---------------|---------|
| Validator 1 | validators-sg | Block production, consensus |
| Validator 2 | validators-sg | Block production, consensus |
| RPC Node | rpc-sg | API queries, Blockscout explorer |
| Monitoring | monitoring-sg | Prometheus, Grafana dashboards |

### Security Groups & Ports

**Validators (validators-sg)**
| Port | Source | Purpose |
|------|--------|---------|
| 22 | Operator IP | SSH |
| 9650 | VPC only | API & metrics (not public) |
| 9651 | 0.0.0.0/0 | P2P consensus |
| 9100 | VPC only | Node exporter |

**RPC Node (rpc-sg)**
| Port | Source | Purpose |
|------|--------|---------|
| 22 | Operator IP | SSH |
| 9650 | Configurable | RPC API (can be public) |
| 9651 | 0.0.0.0/0 | P2P sync |
| 9100 | VPC only | Node exporter |
| 4000-4001 | Configurable | Blockscout |

**Monitoring (monitoring-sg)**
| Port | Source | Purpose |
|------|--------|---------|
| 22 | Operator IP | SSH |
| 3000 | Configurable | Grafana |
| 9090 | VPC only | Prometheus |

### External Access
```
RPC API:    http://<rpc-ip>:9650/ext/bc/<chain>/rpc
Blockscout: http://<rpc-ip>:4001
Grafana:    http://<monitoring-ip>:3000 (admin/admin)
```

## Quick Start (AWS)

### Prerequisites

```bash
brew install terraform ansible awscli jq go
```

> **Note:** Building `create-l1` requires access to `github.com/ava-labs/platform-cli` (private repo).

### 1. Configure AWS & SSH

```bash
# AWS credentials
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."

# Generate SSH key
ssh-keygen -t rsa -b 4096 -f ~/.ssh/avalanche-deploy -N ""
```

### 2. Configure Terraform

```bash
cd terraform/aws
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:
```hcl
name_prefix    = "my-l1"
environment    = "fuji"
validator_count = 2
rpc_count       = 1
ssh_public_key  = "ssh-rsa AAAA..."
ssh_private_key_file = "~/.ssh/avalanche-deploy"
```

### 3. Deploy Infrastructure

```bash
terraform init && terraform apply
cd ../..
```

### 4. Install Avalanchego

```bash
make deploy
make status    # wait for "P:OK" on all nodes
```

### 5. Create Your L1

```bash
# Set your funded P-Chain private key
export AVALANCHE_PRIVATE_KEY="PrivateKey-ewoq..."

# Get validator IPs
export VALIDATORS=$(cd terraform/aws && terraform output -json validator_ips | jq -r 'join(",")')

# Create L1
make create-l1
./tools/create-l1/create-l1 \
  --network=fuji \
  --validators=$VALIDATORS \
  --chain-name=mychain \
  --output=l1.env
```

### 6. Configure Nodes

```bash
source l1.env
make configure-l1 SUBNET_ID=$SUBNET_ID CHAIN_ID=$CHAIN_ID
make status
```

Your L1 is now running.

---

## Optional: Monitoring

```bash
make monitoring
# Access: http://<monitoring-ip>:3000 (admin/admin)
```

## Optional: Blockscout

```bash
source l1.env
make deploy-blockscout CHAIN_ID=$CHAIN_ID EVM_CHAIN_ID=99999 CHAIN_NAME=$CHAIN_NAME
# Access: http://<rpc-ip>:4001
```

The `CHAIN_NAME` parameter sets the network name displayed in Blockscout. If not provided, it defaults to "Avalanche L1".

## Optional: Safe Multisig `[EXPERIMENTAL]`

> **Warning:** Safe is experimental and not production-ready.

See [SAFE.md](SAFE.md) for deploying Gnosis Safe infrastructure.

---

## Cloud Providers

| Provider | Config | Command |
|----------|--------|---------|
| AWS | `terraform/aws/` | `make infra` (default) |
| GCP | `terraform/gcp/` | `make infra CLOUD=gcp` |
| Azure | `terraform/azure/` | `make infra CLOUD=azure` |

## Cost Estimate

| Provider | Monthly (2 val + 1 RPC + monitoring) |
|----------|--------------------------------------|
| AWS | ~$225 |
| GCP | ~$195 |
| Azure | ~$420 |

**Remember:** `make destroy` when done testing!

---

## Configuration Files

| File | Purpose |
|------|---------|
| `genesis.json` | L1 chain config (chainId, alloc, fees) |
| `validator-chain-config.json` | Validator settings (pruning on, fast sync) |
| `rpc-chain-config.json` | RPC settings (archive mode, debug APIs) |

### Genesis Configuration

Use the **[Genesis Builder](https://build.avax.network/tools/l1-toolbox/create-chain)** to generate your `genesis.json` with a visual interface, or edit manually.

Key settings:
- `chainId` - Unique EVM chain ID ([check availability](https://chainlist.org/))
- `feeConfig` - Gas limits and base fees
- `warpConfig` - Cross-chain messaging (Avalanche Interchain Messaging)
- `alloc` - Pre-funded addresses

---

## Commands Reference

| Command | Description |
|---------|-------------|
| `make setup` | Install terraform, ansible, jq |
| `make infra` | Create cloud infrastructure |
| `make deploy` | Install avalanchego on nodes |
| `make status` | Check node sync status |
| `make create-l1` | Build the L1 creation tool |
| `make configure-l1` | Configure nodes for L1 |
| `make monitoring` | Deploy Prometheus + Grafana |
| `make deploy-blockscout` | Deploy block explorer |
| `make safe` | Deploy Safe infrastructure (EXPERIMENTAL) |
| `make safe-genesis` | Merge Safe contracts into genesis (EXPERIMENTAL) |
| `make reset-genesis` | Reset genesis.json to clean state |
| `make reset-l1` | Wipe L1 chain data for redeployment |
| `make logs` | View avalanchego logs |
| `make destroy` | Tear down infrastructure |

---

## Getting a Funded P-Chain Address

You need AVAX on the P-Chain (Fuji testnet) to create an L1.

1. Install [Core Wallet](https://core.app/) and switch to Fuji testnet
2. Get test AVAX from the **[Builder Hub Faucet](https://build.avax.network/tools/faucet)**
3. Cross-chain transfer to P-Chain (Core Wallet → Portfolio → Cross-Chain)
4. Export your private key from Core Wallet

Supported key formats:
- `PrivateKey-ewoqjP7PxY4yr3iLTp...`
- `0x56289e99c94b6912bfc12adc...`

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Ansible can't connect | Check SSH key in `ansible/inventory/aws_hosts` |
| Nodes not syncing | Run `make logs` to view errors |
| "insufficient funds" | Fund your P-Chain address on Fuji |
| "illegal name character" | Chain names must be alphanumeric (no hyphens) |
| Can't reach RPC | Validators don't expose 9650; use RPC node or SSH tunnel |
| "warp cannot be activated before Durango" | Add `"durangoTimestamp": 0` to genesis.json |

---

## Project Structure

```
.
├── terraform/          # Infrastructure as code
│   ├── aws/           # AWS config
│   ├── gcp/           # GCP config
│   └── azure/         # Azure config
├── ansible/           # Configuration management
│   ├── playbooks/     # Deployment phases
│   └── roles/         # avalanchego, prometheus, grafana, blockscout, safe
├── tools/create-l1/   # Go tool for P-Chain transactions
├── shared/            # Genesis templates, dashboards
└── scripts/           # Helper scripts
```

---

## Links

**Builder Hub Tools:**
- [Genesis Builder](https://build.avax.network/tools/l1-toolbox/create-chain) - Generate genesis.json
- [Fuji Faucet](https://build.avax.network/tools/faucet) - Get test AVAX

**Documentation:**
- [Avalanche Deploy Docs](https://build.avax.network/docs/tooling/avalanche-deploy)
- [Avalanche Docs](https://docs.avax.network/)
- [Chain List](https://chainlist.org/) - Check chain ID availability
