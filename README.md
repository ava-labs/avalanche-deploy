# Avalanche L1 Deploy

Deploy an Avalanche L1 (subnet) on Fuji or Mainnet.

```bash
make setup     # install tools
make infra     # create cloud VMs
make deploy    # install avalanchego
make status    # check sync progress
make destroy   # tear down (stops billing!)
```

## Two Deployment Options

| Option | Best For | What It Does |
|--------|----------|--------------|
| **Terraform + Ansible** | VMs on AWS/GCP/Azure | Creates cloud VMs, installs avalanchego |
| **Kubernetes** | Existing K8s cluster | Deploys containers via Helm |

Pick one. Most people start with Terraform + Ansible.

### Default Architecture (2 Validators + 1 RPC + Monitoring)

```
                              ┌──────────────────────────────────────────┐
                              │              Avalanche Network           │
                              │         (Fuji Testnet / Mainnet)         │
                              └─────────────────────┬────────────────────┘
                                                    │
              ┌─────────────────────────────────────┼─────────────────────────────────────┐
              │                         │           │           │                         │
              ▼                         ▼           │           ▼                         ▼
  ┌───────────────────┐    ┌───────────────────┐   │   ┌───────────────────┐    ┌───────────────────┐
  │   Validator 1     │    │   Validator 2     │   │   │    RPC Node       │    │    Monitoring     │
  │   ─────────────   │    │   ─────────────   │   │   │   ─────────────   │    │   ─────────────   │
  │                   │    │                   │   │   │                   │    │                   │
  │  ┌─────────────┐  │    │  ┌─────────────┐  │   │   │  ┌─────────────┐  │    │  ┌─────────────┐  │
  │  │ AvalancheGo │  │◄──►│  │ AvalancheGo │  │◄──┼──►│  │ AvalancheGo │  │    │  │ Prometheus  │  │
  │  │   :9651     │  │P2P │  │   :9651     │  │ P2P   │  │ :9650/:9651 │  │    │  │   :9090     │  │
  │  └─────────────┘  │    │  └─────────────┘  │       │  └─────────────┘  │    │  └──────┬──────┘  │
  │        │          │    │        │          │       │        │          │    │         │         │
  │        │ :9650    │    │        │ :9650    │       │        │ :9650    │    │         ▼         │
  │        │ metrics  │    │        │ metrics  │       │        │ metrics  │    │  ┌─────────────┐  │
  │        └──────────┼────┼────────┴──────────┼───────┼────────┴──────────┼───►│  │  Grafana    │  │
  │                   │    │                   │       │                   │    │  │   :3000     │  │
  │                   │    │                   │       │  ┌─────────────┐  │    │  └─────────────┘  │
  │                   │    │                   │       │  │ Blockscout  │  │    │                   │
  │                   │    │                   │       │  │ :4000/:4001 │  │    │                   │
  │                   │    │                   │       │  │   :8050     │  │    │                   │
  │                   │    │                   │       │  └─────────────┘  │    │                   │
  └───────────────────┘    └───────────────────┘       └───────────────────┘    └───────────────────┘
       Consensus               Consensus                   Public API              Observability
                                                               │                        │
              ┌────────────────────────────────────────────────┴────────────────────────┘
              │
              ▼
  ┌───────────────────────────────────────────────────────────────────────────────────────┐
  │                                   External Access                                     │
  │  • RPC API:     http://<rpc-ip>:9650/ext/bc/<chain>/rpc                              │
  │  • WebSocket:   ws://<rpc-ip>:9650/ext/bc/<chain>/ws                                 │
  │  • Blockscout:  http://<rpc-ip>:4001 (block explorer)                                │
  │  • Grafana:     http://<monitoring-ip>:3000 (dashboards)                             │
  └───────────────────────────────────────────────────────────────────────────────────────┘
```

**Node Roles:**
- **Validators** (2+): Produce blocks, validate transactions. Isolated - only expose P2P port (9651) publicly.
- **RPC Node** (1+): Handles external queries & Blockscout indexing. Keeps validator load low.
- **Monitoring** (1): Dedicated server for Prometheus + Grafana. Scrapes metrics from all nodes via VPC.

---

## Quick Start (AWS)

### Prerequisites

```bash
# Install tools
brew install terraform ansible awscli jq

# Verify
terraform --version
ansible --version
aws --version
```

### 1. Configure AWS

```bash
# Set your AWS credentials
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_SESSION_TOKEN="..."  # if using SSO/temporary creds

# Verify
aws sts get-caller-identity
```

### 2. Setup SSH Key

```bash
# Generate a new key (or use existing)
ssh-keygen -t rsa -b 4096 -f ~/.ssh/avalanche-deploy -N ""

# View public key (you'll need this)
cat ~/.ssh/avalanche-deploy.pub
```

### 3. Configure Terraform

```bash
cd terraform/aws
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:
```hcl
name_prefix = "my-l1"
environment = "fuji"

validator_count = 2  # Minimum recommended
rpc_count       = 1  # For RPC queries and Blockscout

# Paste your public key
ssh_public_key = "ssh-rsa AAAA..."

# Path to private key (for Ansible)
ssh_private_key_file = "~/.ssh/avalanche-deploy"
```

> **Note:** Validators only expose port 9651 (P2P) publicly. Add an RPC node (`rpc_count = 1`) to query your L1 without SSH tunneling.

### 4. Create Infrastructure

```bash
terraform init
terraform apply   # type 'yes' when prompted
cd ../..          # back to repo root
```

### 5. Deploy Nodes

```bash
make deploy
```

### 6. Wait for Sync

Nodes need to sync with Fuji P-Chain before you can create an L1.

```bash
make status   # check sync progress
```

Wait until you see `P:OK` for all nodes.

### 7. Create Genesis

Use the [Avalanche Builder Console](https://build.avax.network/console/layer-1/create/create-chain) to generate your genesis configuration, or edit `genesis.json` directly:

```json
{
  "config": {
    "chainId": 99999,
    "feeConfig": {
      "gasLimit": 15000000,
      "targetBlockRate": 2,
      "minBaseFee": 25000000000
    },
    "subnetEVMTimestamp": 0,
    "durangoTimestamp": 0,
    "etnaTimestamp": 0,
    "warpConfig": {
      "blockTimestamp": 0,
      "quorumNumerator": 67,
      "requirePrimaryNetworkSigners": true
    }
  },
  "alloc": {
    "0xYourAddress": {
      "balance": "0x52B7D2DCC80CD2E4000000"
    }
  }
}
```

Key fields:
- `chainId`: Unique ID for your chain (check [chainlist.org](https://chainlist.org))
- `alloc`: Pre-fund addresses (balance in wei, hex format)
- `feeConfig.minBaseFee`: Minimum gas price in wei
- `durangoTimestamp`, `etnaTimestamp`: **Required** for warp/ICM messaging (set to 0 for genesis activation)
- `warpConfig`: Enable cross-chain messaging (required for ValidatorManager)

### 8. Create Your L1

```bash
# Build the tool
make create-l1

# Set your funded P-Chain private key
export AVALANCHE_PRIVATE_KEY="PrivateKey-ewoq..."
# Or hex format: export AVALANCHE_PRIVATE_KEY="0x..."

# Get validator IPs
export VALIDATORS=$(cd terraform/aws && terraform output -json validator_ips | jq -r 'join(",")')

# Create the L1
./tools/create-l1/create-l1 \
  --network=fuji \
  --validators=$VALIDATORS \
  --chain-name=mychain \
  --validator-balance=1.0 \
  --output=l1.env
```

> **Note:** Chain names must be alphanumeric only (no hyphens or special characters).

#### create-l1 Options

| Flag | Default | Description |
|------|---------|-------------|
| `--network` | `fuji` | Network: `fuji` or `mainnet` |
| `--validators` | - | Comma-separated validator IPs |
| `--chain-name` | `my-l1` | Chain name (alphanumeric only) |
| `--validator-balance` | `1.0` | AVAX per validator (supports decimals: `0.1`, `0.5`) |
| `--genesis` | auto-detect | Path to genesis.json |
| `--genesis-proxy-address` | - | Use pre-deployed proxy as ValidatorManager (e.g., `0xfacade...`) |
| `--private-key` | - | P-Chain private key (or use `AVALANCHE_PRIVATE_KEY` env) |
| `--output` | `l1.env` | Output file for subnet/chain IDs |

#### Low Balance Testing

For testing with minimal P-Chain funds:

```bash
./tools/create-l1/create-l1 \
  --network=fuji \
  --validators=$VALIDATORS \
  --chain-name=TestL1 \
  --validator-balance=0.1 \
  --output=l1.env
```

This creates validators with 0.1 AVAX each instead of 1 AVAX, reducing the total P-Chain requirement.

### 9. Configure Nodes for L1

```bash
source l1.env
make configure-l1 SUBNET_ID=$SUBNET_ID CHAIN_ID=$CHAIN_ID
```

### 10. Done!

```bash
make status   # shows L1 status and RPC endpoint
```

Your RPC endpoint will be displayed. If you added an RPC node, use that IP for queries.

---

## Cleanup (Stop Billing!)

```bash
make destroy   # type 'yes' when prompted
```

---

## Where Do I Get a Private Key?

You need a funded P-Chain address on Fuji.

**Option 1: Core Wallet**
1. Install [Core Wallet](https://core.app/)
2. Switch to Fuji testnet
3. Get test AVAX from [faucet](https://faucet.avax.network/)
4. Export private key from wallet settings

**Option 2: Avalanche-CLI**
```bash
avalanche key create mykey
avalanche key export mykey
```

The private key can be either format:
- Avalanche: `PrivateKey-ewoqjP7PxY4yr3iLTpLisriqt94hdyDFNgchSxGGztUrTXtNN`
- Hex: `0x56289e99c94b6912bfc12adc093c9b51124f0dc54ac7a766b2bc5ccf558d8027`

---

## Kubernetes Option

For existing Kubernetes clusters or local testing with kind:

```bash
cd kubernetes

# Local testing: create kind cluster
./scripts/create-kind-cluster.sh

# Deploy validators
helm install validators ./helm/avalanche-validator \
  --set replicaCount=3 \
  --set network=fuji

# Wait for sync, create L1, configure
./scripts/wait-for-sync.sh
./scripts/create-l1.sh --chain-name=mychain
./scripts/configure-l1.sh

# Check status
./scripts/status.sh
```

See [kubernetes/README.md](kubernetes/README.md) for full documentation.

---

## Configuration Files

The repo includes default configuration files in the root directory that you can customize:

### genesis.json
EVM genesis configuration for your L1 chain. Key settings:
- `chainId`: Unique chain identifier
- `alloc`: Pre-funded addresses
- `feeConfig`: Gas limits and base fees
- `warpConfig`: Cross-chain messaging settings

### validator-chain-config.json
Subnet-EVM chain config for **validators**:
- **Pruning enabled**: Reduces disk usage by pruning old state
- **Block timing**: `min-block-delay: 250ms` for faster block production
- **State sync enabled**: Faster initial sync

```json
{
  "pruning-enabled": true,
  "state-sync-enabled": true,
  "min-block-delay": "250ms"
}
```

### rpc-chain-config.json
Subnet-EVM chain config for **RPC/archive nodes**:
- **Pruning disabled**: Keeps full historical state for queries
- **Debug APIs**: Enables `debug-tracer` for transaction tracing
- **State sync disabled**: Full sync for complete history

```json
{
  "pruning-enabled": false,
  "state-sync-enabled": false,
  "eth-apis": ["eth", "eth-filter", "net", "web3", "internal-debug", "debug-tracer"]
}
```

### validator-node-config.json / rpc-node-config.json
AvalancheGo node configuration. Key difference:
- **Validators**: `index-enabled: false` (no indexing needed)
- **RPC nodes**: `index-enabled: true` (enables transaction indexing for queries)

These settings are applied via Ansible. Edit the files and re-run `make deploy` to apply changes.

---

## ValidatorManager with Genesis Proxy (Advanced)

For production L1s, you can pre-deploy a TransparentUpgradeableProxy in genesis with a vanity address, then upgrade it to the ValidatorManager implementation after L1 conversion.

### Why Use a Genesis Proxy?

- **Deterministic addresses**: Use vanity addresses like `0xfacade...` for your ValidatorManager
- **Upgradeable**: Proxy pattern allows upgrading the implementation later
- **Clean deployment**: Contracts in genesis, no deployment transactions needed

### Setup

1. **Add proxy contracts to genesis.json** (see `genesis.json` for example):
   - TransparentUpgradeableProxy at vanity address (e.g., `0xfacade0000000000000000000000000000000000`)
   - ProxyAdmin at another address (e.g., `0xdad0000000000000000000000000000000000000`)
   - Set EIP-1967 storage slots for admin and implementation

2. **Create L1 with genesis proxy**:
   ```bash
   ./tools/create-l1/create-l1 \
     --network=fuji \
     --validators=$VALIDATORS \
     --chain-name=MyL1 \
     --genesis-proxy-address=0xfacade0000000000000000000000000000000000 \
     --output=l1.env
   ```

3. **After L1 conversion**, deploy the ValidatorManager implementation and upgrade the proxy using your ProxyAdmin.

4. **Call `initializeValidatorSet`** on the proxy to register validators.

---

## Deploy Monitoring (Prometheus + Grafana)

Deploy monitoring stack to track node health and performance. Monitoring runs on a **dedicated lightweight server** (t3.small/e2-small) separate from validators to keep them isolated.

```bash
cd ansible
ansible-playbook playbooks/03-setup-monitoring.yml \
  -i inventory/aws_hosts
```

Access Grafana at `http://<monitoring-ip>:3000` (default credentials: admin/admin).

```bash
# Get the Grafana URL
cd terraform/aws && terraform output grafana_url

# Get the monitoring server IP
terraform output monitoring_ip
```

**Architecture:**
- Prometheus runs on the dedicated monitoring server
- Scrapes metrics from all validators and RPC nodes via private IPs (VPC internal)
- Grafana dashboards show:
  - Node health (P-Chain, X-Chain, C-Chain, L1 chain status)
  - Resource usage (CPU, memory, disk, network)
  - Avalanche metrics (block height, tx throughput, peers)

---

## Deploy Blockscout Block Explorer

After your L1 is running, deploy Blockscout to explore transactions. Blockscout runs on the **RPC node** alongside the chain data it indexes.

```bash
# Source your L1 config
source l1.env

# Deploy Blockscout to RPC node
cd ansible
ansible-playbook playbooks/04-deploy-blockscout.yml \
  -i inventory/aws_hosts \
  -e "chain_id=$CHAIN_ID" \
  -e "evm_chain_id=99999" \
  -e "l1_name=MyL1" \
  -e "coin_symbol=TOKEN"
```

Blockscout will be available at:
- **Frontend**: http://\<rpc-ip\>:4001
- **API**: http://\<rpc-ip\>:4000/api
- **Stats**: http://\<rpc-ip\>:8050/api

```bash
# Get the Blockscout URL
cd terraform/aws && terraform output blockscout_url
```

**Architecture:**
- Blockscout runs on the RPC node (co-located with the data it indexes)
- Uses `host.docker.internal` to connect to local AvalancheGo RPC
- Stats service provides chart data for the frontend

---

## Terraform Outputs

After `terraform apply`, useful outputs are available:

```bash
cd terraform/aws

# Get all outputs
terraform output

# Specific outputs
terraform output validator_ips         # Validator public IPs
terraform output rpc_ips               # RPC node public IPs
terraform output monitoring_ip         # Dedicated monitoring server IP
terraform output monitoring_private_ip # Monitoring server private IP (for VPC)
terraform output grafana_url           # Grafana dashboard URL
terraform output blockscout_url        # Blockscout explorer URL (on RPC node)
```

---

## Full Deployment Workflow

Complete workflow from zero to running L1 with monitoring:

```bash
# 1. Infrastructure
cd terraform/aws
terraform init && terraform apply

# 2. Deploy nodes
cd ../..
make deploy

# 3. Wait for P-Chain sync
make status  # wait for P:OK on all nodes

# 4. Create L1
source /tmp/aws_creds.env  # or set AWS creds
export AVALANCHE_PRIVATE_KEY="0x..."
export VALIDATORS=$(cd terraform/aws && terraform output -json validator_ips | jq -r 'join(",")')
./tools/create-l1/create-l1 --network=fuji --validators=$VALIDATORS --chain-name=MyL1 --output=l1.env

# 5. Configure nodes for L1
source l1.env
make configure-l1 SUBNET_ID=$SUBNET_ID CHAIN_ID=$CHAIN_ID

# 6. Deploy monitoring
cd ansible && ansible-playbook playbooks/03-setup-monitoring.yml -i inventory/aws_hosts

# 7. Deploy Blockscout
RPC_IP=$(cd ../terraform/aws && terraform output -json rpc_ips | jq -r '.[0]')
ansible-playbook playbooks/04-deploy-blockscout.yml -i inventory/aws_hosts -e "chain_id=$CHAIN_ID" -e "l1_rpc_url=http://$RPC_IP:9650/ext/bc/$CHAIN_ID/rpc"

# 8. Get URLs
cd ../terraform/aws
echo "RPC: http://$(terraform output -json rpc_ips | jq -r '.[0]'):9650/ext/bc/$CHAIN_ID/rpc"
terraform output grafana_url
terraform output blockscout_url
```

---

## Cost Estimate

| Cloud | Node Instances | Monitoring | Monthly Total (2 validators + 1 RPC + monitoring) |
|-------|----------------|------------|---------------------------------------------------|
| AWS   | m6id.large     | t3.small   | ~$225 |
| GCP   | n2-standard-2 + local SSD | e2-small | ~$195 |
| Azure | Standard_L8s_v3 | Standard_B2s | ~$420 |

Remember to `make destroy` when done testing!

---

## Troubleshooting

**Ansible can't connect**
```bash
# Test SSH manually
ssh -i ~/.ssh/avalanche-deploy ubuntu@<IP>

# Check inventory has your key
cat ansible/inventory/aws_hosts
```

**Nodes not syncing**
```bash
make logs   # view avalanchego logs
```

**create-l1 fails with "insufficient funds"**
```bash
# Check you have AVAX on P-Chain
# Go to https://subnets.avax.network/fuji and search your address
```

**create-l1 fails with "illegal name character"**
```bash
# Chain names must be alphanumeric only
# Use: mychain, testl1, prodchain
# Not: my-chain, test_l1, prod.chain
```

**Can't reach RPC endpoint**
```bash
# Validators don't expose 9650 publicly (security)
# Option 1: Add an RPC node (rpc_count = 1 in terraform.tfvars)
# Option 2: SSH tunnel: ssh -L 9650:localhost:9650 ubuntu@<validator-ip>
```

**Chain fails with "warp cannot be activated before Durango"**
```bash
# Your genesis.json is missing upgrade timestamps
# Add these to the config section:
"subnetEVMTimestamp": 0,
"durangoTimestamp": 0,
"etnaTimestamp": 0
```

**create-l1 fails with "insufficient funds" for low amounts**
```bash
# Use fractional balance flag
./tools/create-l1/create-l1 --validator-balance=0.1 ...
# This requires only 0.3 AVAX total for 3 validators instead of 3 AVAX
```
