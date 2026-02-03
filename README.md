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

```
                         Avalanche Network (Fuji/Mainnet)
                                    │
          ┌─────────────────────────┼─────────────────────────┐
          │                         │                         │
          ▼                         ▼                         ▼
    ┌───────────┐            ┌───────────┐            ┌───────────┐
    │ Validator │◄──── P2P ──►│ Validator │◄─── P2P ──►│    RPC    │
    │     1     │             │     2     │            │   Node    │
    │   :9651   │             │   :9651   │            │:9650/:9651│
    └─────┬─────┘             └─────┬─────┘            └─────┬─────┘
          │                         │                        │
          └─────────────────────────┴────────────────────────┘
                                    │ metrics
                                    ▼
                             ┌─────────────┐
                             │  Monitoring │
                             │  Prometheus │
                             │ Grafana:3000│
                             └─────────────┘

External Access:
  • RPC API:    http://<rpc-ip>:9650/ext/bc/<chain>/rpc
  • Blockscout: http://<rpc-ip>:4001
  • Grafana:    http://<monitoring-ip>:3000
```

## Quick Start (AWS)

### Prerequisites

```bash
brew install terraform ansible awscli jq go
```

**Go private dependency setup** (required for building `create-l1`):
```bash
go env -w GOPRIVATE=github.com/ava-labs/platform-cli
git config --global url."git@github.com:".insteadOf "https://github.com/"
```

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

### Genesis Example

```json
{
  "config": {
    "chainId": 99999,
    "feeConfig": {
      "gasLimit": 15000000,
      "targetBlockRate": 2,
      "minBaseFee": 25000000000
    },
    "warpConfig": {
      "blockTimestamp": 0,
      "quorumNumerator": 67
    }
  },
  "alloc": {
    "0xYourAddress": {
      "balance": "0x52B7D2DCC80CD2E4000000"
    }
  }
}
```

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

## Getting a Private Key

You need a funded P-Chain address on Fuji.

**Option 1: Core Wallet**
1. Install [Core Wallet](https://core.app/)
2. Switch to Fuji testnet
3. Get AVAX from [faucet](https://faucet.avax.network/)
4. Export private key

**Option 2: Avalanche CLI**
```bash
avalanche key create mykey
avalanche key export mykey
```

Supported formats:
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

- [Avalanche Builders Hub - Avalanche Deploy Docs](https://build.avax.network/docs/tooling/avalanche-deploy)
- [Avalanche Docs](https://docs.avax.network/)
- [Builder Console](https://build.avax.network/) - Generate genesis configs
- [Fuji Faucet](https://faucet.avax.network/) - Get test AVAX
- [Chain List](https://chainlist.org/) - Check chain ID availability
