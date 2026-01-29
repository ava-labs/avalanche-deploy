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

## Quick Start (AWS + Ansible)

### Prerequisites

```bash
# Install tools
brew install terraform ansible awscli

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

# Create config
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:
```hcl
name_prefix = "my-l1"
environment = "fuji"

validator_count = 3
rpc_count       = 0

# Paste your public key here
ssh_public_key = "ssh-rsa AAAA..."

# Path to private key (for Ansible)
ssh_private_key_file = "~/.ssh/avalanche-deploy"
```

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

Nodes need to sync with Fuji (~10-30 min).

```bash
make status                    # check once
# or
./scripts/wait-for-sync.sh     # wait with spinner
```

### 7. Customize Genesis (Optional)

Edit `genesis.json` in the repo root to customize your L1:

```bash
# Key fields:
# - chainId: Pick a unique ID (check chainlist.org)
# - alloc: Pre-fund addresses with native token
# - feeConfig: Gas limits and base fees
```

See [GENESIS.md](GENESIS.md) for all options.

### 8. Create Your L1

```bash
# Build the tool
make create-l1

# Set your funded P-Chain private key (see "Where Do I Get a Private Key?" below)
export AVALANCHE_PRIVATE_KEY="PrivateKey-ewoq..."

# Optional: Set validator balance (default: 1 AVAX per validator)
export L1_VALIDATOR_BALANCE_AVAX=5

# Get validator IPs
export VALIDATORS=$(cd terraform/aws && terraform output -json validator_ips | jq -r 'join(",")')

# Create the L1! (auto-finds genesis.json in repo root)
./tools/create-l1/create-l1 \
  --network=fuji \
  --validators=$VALIDATORS \
  --chain-name=my-l1 \
  --output=l1.env
```

### 9. Configure Nodes for L1

```bash
source l1.env
make configure-l1 SUBNET_ID=$SUBNET_ID CHAIN_ID=$CHAIN_ID
```

### 10. Done!

```bash
IP=$(cd terraform/aws && terraform output -json validator_ips | jq -r '.[0]')
echo "RPC: http://$IP:9650/ext/bc/$CHAIN_ID/rpc"
```

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

The private key format is: `PrivateKey-ewoqjP7PxY4yr3iLTpLisriqt94hdyDFNgchSxGGztUrTXtNN`

---

## Kubernetes Option

If you have an existing Kubernetes cluster:

```bash
cd kubernetes/helm

# Install validators
helm install my-l1-validators ./avalanche-validator \
  --set replicaCount=3 \
  --set network=fuji

# Check status
kubectl get pods -l app=avalanche-validator
```

See [kubernetes/README.md](kubernetes/README.md) for details.

---

## Cost Estimate

| Cloud | Instance | Monthly Cost (3 validators) |
|-------|----------|----------------------------|
| AWS   | m6id.large | ~$210 |
| GCP   | n2-standard-2 + local SSD | ~$180 |
| Azure | Standard_L8s_v3 | ~$400 |

Remember to `terraform destroy` when done testing!

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

**create-l1 fails**
```bash
# Check node is healthy
make status

# Check you have AVAX on P-Chain
# Go to https://subnets.avax.network/fuji and search your address
```
