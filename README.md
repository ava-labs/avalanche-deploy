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

validator_count = 3
rpc_count       = 1  # Add an RPC node for querying

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
  --output=l1.env
```

> **Note:** Chain names must be alphanumeric only (no hyphens or special characters).

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

## Cost Estimate

| Cloud | Instance | Monthly Cost (3 validators + 1 RPC) |
|-------|----------|-------------------------------------|
| AWS   | m6id.large | ~$280 |
| GCP   | n2-standard-2 + local SSD | ~$240 |
| Azure | Standard_L8s_v3 | ~$530 |

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
