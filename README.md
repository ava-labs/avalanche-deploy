# Avalanche Deploy

Infrastructure deployment toolkit for Avalanche L1s on **Fuji** and **Mainnet**.

This repo provides multiple deployment paths - pick what fits your infrastructure:

| Path | Best For | Components |
|------|----------|------------|
| **Terraform + Ansible** | VMs on AWS/GCP/Azure | Provision VMs, configure with Ansible |
| **Kubernetes** | Container orchestration | Helm charts or raw manifests |

## Quick Start

### Option 1: Terraform + Ansible (VMs)

```bash
# 1. Provision infrastructure
cd terraform/aws  # or gcp, azure
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your settings
terraform init && terraform apply

# 2. Configure nodes
cd ../../ansible
# Terraform outputs inventory automatically
ansible-playbook playbooks/site.yml

# 3. Create L1
cd ../tools/create-l1
go build -o create-l1 .
./create-l1 --network=fuji --private-key=$YOUR_FUNDED_KEY --config=../../deploy.yaml
```

### Option 2: Kubernetes

```bash
# Using Helm
helm install avalanche-validators ./kubernetes/helm/avalanche-validator \
  --set network=fuji \
  --set validators.count=3

helm install avalanche-rpc ./kubernetes/helm/avalanche-rpc \
  --set network=fuji

helm install monitoring ./kubernetes/helm/monitoring

# Or raw manifests
kubectl apply -k ./kubernetes/manifests/overlays/fuji/
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Avalanche Network                         │
│                      (Fuji or Mainnet)                          │
└─────────────────────────────────────────────────────────────────┘
                              ▲
                              │ P-Chain: Subnet/L1 registration
                              │ Validators track primary network
                              │
┌─────────────────────────────────────────────────────────────────┐
│                         Your L1                                  │
├─────────────────┬─────────────────┬─────────────────────────────┤
│   Validator 1   │   Validator 2   │   Validator N...            │
│   (L1 only)     │   (L1 only)     │   (L1 only)                 │
├─────────────────┴─────────────────┴─────────────────────────────┤
│                         RPC Nodes                                │
│              (API access, not validating)                        │
└─────────────────────────────────────────────────────────────────┘
                              ▲
                              │
┌─────────────────────────────────────────────────────────────────┐
│                        Monitoring                                │
│                   Prometheus + Grafana                          │
└─────────────────────────────────────────────────────────────────┘
```

## Directory Structure

```
avalanche-deploy/
├── shared/                 # Common configs (used by all paths)
│   ├── genesis/           # Genesis templates
│   ├── configs/           # Node & chain configs
│   └── dashboards/        # Grafana dashboards
│
├── terraform/             # Infrastructure provisioning
│   ├── aws/              # Amazon Web Services
│   ├── gcp/              # Google Cloud Platform
│   ├── azure/            # Microsoft Azure
│   └── modules/          # Shared Terraform modules
│
├── ansible/               # VM configuration
│   ├── playbooks/        # Main playbooks
│   └── roles/            # Reusable roles
│
├── kubernetes/            # Container orchestration
│   ├── helm/             # Helm charts
│   └── manifests/        # Raw K8s manifests
│
└── tools/                 # CLI tools
    └── create-l1/        # L1 creation tool (BYOK)
```

## Configuration

### Network Selection

Set `network` to `fuji` or `mainnet` in your config:

```yaml
# deploy.yaml
network: fuji  # or mainnet

validators:
  count: 3

rpc_nodes:
  count: 2

vm:
  type: subnet-evm  # default, or provide custom
  # binary: /path/to/custom-vm  # for custom VMs
```

### Bring Your Own Key (BYOK)

You need a funded P-Chain address to create an L1. The `create-l1` tool accepts your private key:

```bash
# From environment variable (recommended)
export AVALANCHE_PRIVATE_KEY=PrivateKey-...
./create-l1 --network=fuji --config=deploy.yaml

# Or from file
./create-l1 --network=fuji --private-key-file=~/.avalanche/key.txt --config=deploy.yaml
```

**Funding requirements:**
- Fuji: Get test AVAX from [faucet](https://faucet.avax.network/)
- Mainnet: Real AVAX required for subnet creation + validator registration

## Monitoring

Both deployment paths include Prometheus + Grafana:

- **Terraform/Ansible**: Grafana on first validator, port 3000
- **Kubernetes**: Grafana service exposed via LoadBalancer or Ingress

Pre-built dashboard tracks:
- TPS, block times, gas usage
- Validator health, poll success rates
- TX pool depth, verification times

## Requirements

### Terraform + Ansible
- Terraform >= 1.5
- Ansible >= 2.15
- Go >= 1.21 (for create-l1 tool)
- Cloud provider credentials (AWS/GCP/Azure)

### Kubernetes
- kubectl
- Helm >= 3.12
- Access to a Kubernetes cluster

## License

MIT
