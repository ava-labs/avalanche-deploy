# Avalanche L1 Deploy - Common Commands
#
# Usage:
#   make setup      - Install dependencies
#   make infra      - Create AWS infrastructure
#   make deploy     - Deploy nodes
#   make status     - Check node status
#   make create-l1  - Build create-l1 tool
#   make destroy    - Tear down everything

SHELL := /bin/bash
.PHONY: setup infra deploy status create-l1 deploy-blockscout safe safe-genesis reset-genesis reset-l1 destroy clean logs rolling-restart health-checks faucet upgrade graph-node erpc init-validator-manager initialize-validator-manager primary-infra primary-deploy primary-status backup-keys restore-keys prepare-migration migrate-validator create-snapshot restore-snapshot list-snapshots lint validate test-e2e-l1 test-e2e-primary

# Default cloud provider
CLOUD ?= aws
NETWORK ?= fuji

#
# Setup
#
setup:
	@echo "Installing dependencies..."
	@which terraform > /dev/null || brew install terraform
	@which ansible > /dev/null || brew install ansible
	@which aws > /dev/null || brew install awscli
	@which jq > /dev/null || brew install jq
	@echo "Done! Run 'make infra' next."

#
# Infrastructure
#
infra:
	@echo "Creating $(CLOUD) infrastructure..."
	@cd terraform/$(CLOUD) && terraform init && terraform apply
	@echo ""
	@echo "Done! Run 'make deploy' next."

infra-plan:
	@cd terraform/$(CLOUD) && terraform plan

#
# Deploy
#
deploy:
	@echo "Deploying nodes..."
	@cd ansible && ansible-playbook playbooks/01-deploy-nodes.yml -e network=$(NETWORK)
	@echo ""
	@echo "Done! Run 'make status' to check sync progress."

configure-l1:
	@if [ -z "$(SUBNET_ID)" ]; then echo "Usage: make configure-l1 SUBNET_ID=xxx CHAIN_ID=yyy"; exit 1; fi
	@cd ansible && ansible-playbook playbooks/02-configure-l1.yml \
		-e subnet_id=$(SUBNET_ID) \
		-e chain_id=$(CHAIN_ID)

reset-l1:
	@echo "Resetting L1 chain data on all nodes..."
	@cd ansible && ansible-playbook playbooks/00-reset-l1.yml

monitoring:
	@cd ansible && ansible-playbook playbooks/03-setup-monitoring.yml

rolling-restart:
	@echo "Performing rolling restart of all nodes..."
	@cd ansible && ansible-playbook playbooks/rolling-restart.yml

health-checks:
	@cd ansible && ansible-playbook playbooks/health-checks.yml $(if $(CHAIN_ID),-e chain_id=$(CHAIN_ID),)

upgrade:
	@if [ -z "$(VERSION)" ]; then echo "Usage: make upgrade VERSION=1.12.0"; exit 1; fi
	@echo "Upgrading nodes to avalanchego $(VERSION)..."
	@echo "NOTE: subnet-evm is bundled with avalanchego and will be updated automatically."
	@cd ansible && ansible-playbook playbooks/upgrade-nodes.yml \
		-e "avalanchego_version=$(VERSION)"

#
# Status
#
status:
	@./scripts/status.sh $(CLOUD)

logs:
	@IP=$$(cd terraform/$(CLOUD) && terraform output -json validator_ips 2>/dev/null | jq -r '.[0]'); \
	KEY=$$(cd terraform/$(CLOUD) && terraform output -raw ssh_private_key_file 2>/dev/null || echo "~/.ssh/avalanche-deploy"); \
	ssh -i $$KEY ubuntu@$$IP "sudo journalctl -u avalanchego -f --no-pager -n 50"

#
# Tools
#
create-l1:
	@echo "Building create-l1 tool..."
	@cd tools/create-l1 && go mod tidy && go build -o create-l1 .
	@echo "Done! Binary at tools/create-l1/create-l1"

#
# Blockscout Block Explorer
#
deploy-blockscout:
	@if [ -z "$(CHAIN_ID)" ]; then echo "Usage: make deploy-blockscout CHAIN_ID=xxx EVM_CHAIN_ID=yyy [CHAIN_NAME=name]"; exit 1; fi
	@if [ -z "$(EVM_CHAIN_ID)" ]; then echo "Usage: make deploy-blockscout CHAIN_ID=xxx EVM_CHAIN_ID=yyy [CHAIN_NAME=name]"; exit 1; fi
	@echo "Deploying Blockscout block explorer..."
	@cd ansible && ansible-playbook playbooks/04-deploy-blockscout.yml \
		-e "l1_chain_id=$(CHAIN_ID)" \
		-e "l1_evm_chain_id=$(EVM_CHAIN_ID)" \
		-e "l1_name=$(or $(CHAIN_NAME),Avalanche L1)"

#
# Faucet
#
faucet:
	@if [ -z "$(CHAIN_ID)" ]; then echo "Usage: make faucet CHAIN_ID=xxx EVM_CHAIN_ID=yyy FAUCET_KEY=0x..."; exit 1; fi
	@if [ -z "$(EVM_CHAIN_ID)" ]; then echo "Usage: make faucet CHAIN_ID=xxx EVM_CHAIN_ID=yyy FAUCET_KEY=0x..."; exit 1; fi
	@if [ -z "$(FAUCET_KEY)" ]; then echo "Usage: make faucet CHAIN_ID=xxx EVM_CHAIN_ID=yyy FAUCET_KEY=0x..."; exit 1; fi
	@echo "Deploying faucet..."
	@cd ansible && ansible-playbook playbooks/06-deploy-faucet.yml \
		-e "l1_chain_id=$(CHAIN_ID)" \
		-e "l1_evm_chain_id=$(EVM_CHAIN_ID)" \
		-e "faucet_private_key=$(FAUCET_KEY)"

#
# The Graph Node
#
graph-node:
	@if [ -z "$(CHAIN_ID)" ]; then echo "Usage: make graph-node CHAIN_ID=xxx [NETWORK_NAME=my-l1]"; exit 1; fi
	@echo "Deploying The Graph Node..."
	@cd ansible && ansible-playbook playbooks/07-deploy-graph-node.yml \
		-e "l1_chain_id=$(CHAIN_ID)" \
		$(if $(NETWORK_NAME),-e "graph_network_name=$(NETWORK_NAME)",)

erpc:
	@if [ -z "$(CHAIN_ID)" ]; then echo "Usage: make erpc CHAIN_ID=xxx EVM_CHAIN_ID=yyy"; exit 1; fi
	@if [ -z "$(EVM_CHAIN_ID)" ]; then echo "Usage: make erpc CHAIN_ID=xxx EVM_CHAIN_ID=yyy"; exit 1; fi
	@echo "Deploying eRPC load balancer..."
	@cd ansible && ansible-playbook playbooks/08-deploy-erpc.yml \
		-e "l1_chain_id=$(CHAIN_ID)" \
		-e "l1_evm_chain_id=$(EVM_CHAIN_ID)"

#
# Validator Manager
#
init-validator-manager:
	@echo "Building initialize-validator-manager tool..."
	@cd tools/initialize-validator-manager && go mod tidy && go build -o initialize-validator-manager .
	@echo "Done! Binary at tools/initialize-validator-manager/initialize-validator-manager"

initialize-validator-manager:
	@if [ -z "$(SUBNET_ID)" ]; then echo "Usage: make initialize-validator-manager SUBNET_ID=xxx CHAIN_ID=yyy CONVERSION_TX=zzz PROXY_ADDRESS=0x... EVM_CHAIN_ID=12345"; exit 1; fi
	@if [ -z "$(CHAIN_ID)" ]; then echo "Usage: make initialize-validator-manager SUBNET_ID=xxx CHAIN_ID=yyy CONVERSION_TX=zzz PROXY_ADDRESS=0x... EVM_CHAIN_ID=12345"; exit 1; fi
	@if [ -z "$(CONVERSION_TX)" ]; then echo "Usage: make initialize-validator-manager SUBNET_ID=xxx CHAIN_ID=yyy CONVERSION_TX=zzz PROXY_ADDRESS=0x... EVM_CHAIN_ID=12345"; exit 1; fi
	@if [ -z "$(PROXY_ADDRESS)" ]; then echo "Usage: make initialize-validator-manager SUBNET_ID=xxx CHAIN_ID=yyy CONVERSION_TX=zzz PROXY_ADDRESS=0x... EVM_CHAIN_ID=12345"; exit 1; fi
	@if [ -z "$(EVM_CHAIN_ID)" ]; then echo "Usage: make initialize-validator-manager SUBNET_ID=xxx CHAIN_ID=yyy CONVERSION_TX=zzz PROXY_ADDRESS=0x... EVM_CHAIN_ID=12345"; exit 1; fi
	@echo "Initializing Validator Manager..."
	@cd ansible && ansible-playbook playbooks/09-initialize-validator-manager.yml \
		-e "subnet_id=$(SUBNET_ID)" \
		-e "chain_id=$(CHAIN_ID)" \
		-e "conversion_tx=$(CONVERSION_TX)" \
		-e "proxy_address=$(PROXY_ADDRESS)" \
		-e "evm_chain_id=$(EVM_CHAIN_ID)" \
		$(if $(MANAGER_TYPE),-e "manager_type=$(MANAGER_TYPE)",) \
		$(if $(ICM_CONTRACTS_PATH),-e "icm_contracts_path=$(ICM_CONTRACTS_PATH)",)

#
# Primary Network Validators
#
primary-infra:
	@echo "Creating Primary Network validator infrastructure..."
	@cd terraform/$(CLOUD) && terraform init && terraform apply -var="primary_validator_count=1"
	@echo ""
	@echo "Done! Run 'make primary-deploy' next."

primary-deploy:
	@echo "Deploying Primary Network validators..."
	@cd ansible && ansible-playbook playbooks/10-deploy-primary-network.yml -e network=$(NETWORK)
	@echo ""
	@echo "Done! Run 'make primary-status' to check sync progress."

primary-status:
	@./scripts/check-primary-sync.sh

backup-keys:
	@echo "Backing up staking keys to S3 (L1 + Primary Network validators)..."
	@cd ansible && ansible-playbook playbooks/11-backup-staking-keys.yml

restore-keys:
	@if [ -z "$(SOURCE)" ]; then echo "Usage: make restore-keys SOURCE=primary-validator-1 TARGET_IP=10.0.1.50"; exit 1; fi
	@if [ -z "$(TARGET_IP)" ]; then echo "Usage: make restore-keys SOURCE=primary-validator-1 TARGET_IP=10.0.1.50"; exit 1; fi
	@./scripts/restore-staking-keys.sh $(SOURCE) $(TARGET_IP)

prepare-migration:
	@if [ -z "$(NODE)" ]; then echo "Usage: make prepare-migration NODE=migration-target [SNAPSHOT=true] [SNAPSHOT_NAME=latest]"; exit 1; fi
	@echo "Preparing migration node $(NODE)..."
	@cd ansible && ansible-playbook playbooks/12-prepare-migration-node.yml --limit $(NODE) \
		$(if $(SNAPSHOT),-e "use_snapshot=$(SNAPSHOT)",) \
		$(if $(SNAPSHOT_NAME),-e "snapshot_name=$(SNAPSHOT_NAME)",)

migrate-validator:
	@if [ -z "$(SOURCE)" ]; then echo "Usage: make migrate-validator SOURCE=primary-validator-1 TARGET=migration-target"; exit 1; fi
	@if [ -z "$(TARGET)" ]; then echo "Usage: make migrate-validator SOURCE=primary-validator-1 TARGET=migration-target"; exit 1; fi
	@echo "Migrating validator from $(SOURCE) to $(TARGET)..."
	@cd ansible && ansible-playbook playbooks/13-migrate-validator.yml \
		-e "source_host=$(SOURCE)" \
		-e "target_host=$(TARGET)"

#
# Database Snapshots
#
create-snapshot:
	@if [ -z "$(NODE)" ]; then echo "Usage: make create-snapshot NODE=primary-validator-1 [NAME=my-snapshot]"; exit 1; fi
	@echo "Creating database snapshot from $(NODE)..."
	@cd ansible && ansible-playbook playbooks/14-create-snapshot.yml --limit $(NODE) \
		$(if $(NAME),-e "snapshot_name=$(NAME)",)

restore-snapshot:
	@if [ -z "$(TARGET)" ]; then echo "Usage: make restore-snapshot TARGET=migration-target [SNAPSHOT=latest]"; exit 1; fi
	@echo "Restoring snapshot to $(TARGET)..."
	@cd ansible && ansible-playbook playbooks/15-restore-snapshot.yml --limit $(TARGET) \
		$(if $(SNAPSHOT),-e "snapshot_name=$(SNAPSHOT)",)

list-snapshots:
	@./scripts/list-snapshots.sh

#
# Safe Multisig
#
safe:
	@if [ -z "$(CHAIN_ID)" ]; then echo "Usage: make safe CHAIN_ID=xxx EVM_CHAIN_ID=yyy"; exit 1; fi
	@if [ -z "$(EVM_CHAIN_ID)" ]; then echo "Usage: make safe CHAIN_ID=xxx EVM_CHAIN_ID=yyy"; exit 1; fi
	@cd ansible && ansible-playbook playbooks/05-deploy-safe.yml \
		-e "chain_id=$(CHAIN_ID)" \
		-e "evm_chain_id=$(EVM_CHAIN_ID)"

safe-genesis:
	@echo "=============================================="
	@echo "  EXPERIMENTAL: Safe Multisig Genesis Merge"
	@echo "=============================================="
	@./shared/safe/merge-genesis.sh genesis.json

reset-genesis:
	@echo "Resetting genesis.json to clean state..."
	@cp shared/genesis-templates/genesis-clean.json genesis.json
	@echo "Done! genesis.json reset (Safe contracts removed)"

#
# Testing & Validation
#
lint:
	@echo "Running linters..."
	@which ansible-lint > /dev/null || (echo "Installing ansible-lint..." && pip install ansible-lint)
	@cd ansible && ansible-lint playbooks/*.yml || true
	@echo ""
	@echo "Checking Terraform format..."
	@cd terraform/aws && terraform fmt -check -recursive || true
	@cd terraform/gcp && terraform fmt -check -recursive || true
	@cd terraform/azure && terraform fmt -check -recursive || true
	@echo "Done!"

validate:
	@echo "Validating Ansible playbooks..."
	@cd ansible && for f in playbooks/*.yml; do \
		echo "  Checking $$f..."; \
		ansible-playbook --syntax-check "$$f" > /dev/null || exit 1; \
	done
	@echo "✓ All Ansible playbooks valid"
	@echo ""
	@echo "Validating Terraform configurations..."
	@cd terraform/aws && terraform init -backend=false > /dev/null && terraform validate
	@echo "✓ AWS terraform valid"
	@cd terraform/gcp && terraform init -backend=false > /dev/null && terraform validate
	@echo "✓ GCP terraform valid"
	@cd terraform/azure && terraform init -backend=false > /dev/null && terraform validate
	@echo "✓ Azure terraform valid"
	@echo ""
	@echo "All validations passed!"

test-e2e-l1:
	@echo "Running L1 E2E test..."
	@./tests/e2e-l1.sh

test-e2e-primary:
	@echo "Running Primary Network E2E test..."
	@./tests/e2e-primary-network.sh

#
# Cleanup
#
destroy:
	@echo "Destroying $(CLOUD) infrastructure..."
	@cd terraform/$(CLOUD) && terraform destroy
	@echo "Done!"

clean:
	@rm -f ansible/node_ids.txt
	@rm -f l1.env
	@rm -f validator-manager.json
	@rm -f tools/create-l1/create-l1
	@rm -f tools/initialize-validator-manager/initialize-validator-manager
	@echo "Cleaned up generated files."

#
# Help
#
help:
	@echo "Avalanche L1 Deploy"
	@echo ""
	@echo "Quick start (L1):"
	@echo "  make setup        Install dependencies (terraform, ansible, aws-cli)"
	@echo "  make infra        Create cloud infrastructure"
	@echo "  make deploy       Deploy avalanchego to nodes"
	@echo "  make status       Check node sync status"
	@echo "  make create-l1    Build the create-l1 tool"
	@echo "  make destroy      Tear down infrastructure (stops billing!)"
	@echo ""
	@echo "Primary Network Validators:"
	@echo "  make primary-infra      Create Primary Network validator infrastructure"
	@echo "  make primary-deploy     Deploy avalanchego for Primary Network"
	@echo "  make primary-status     Check Primary Network sync status (P/X/C chains)"
	@echo "  make backup-keys        Backup staking keys to S3"
	@echo "  make restore-keys       Restore staking keys from S3"
	@echo "  make prepare-migration  Prepare a new node for migration (supports SNAPSHOT=true)"
	@echo "  make migrate-validator  Execute zero-downtime validator migration"
	@echo ""
	@echo "Database Snapshots:"
	@echo "  make create-snapshot    Create database snapshot from synced node"
	@echo "  make restore-snapshot   Restore database snapshot to a node"
	@echo "  make list-snapshots     List available snapshots in S3"
	@echo ""
	@echo "Operations:"
	@echo "  make rolling-restart   Restart nodes one-at-a-time (zero downtime)"
	@echo "  make upgrade           Upgrade avalanchego (subnet-evm bundled)"
	@echo "  make health-checks     Run comprehensive health checks on all nodes"
	@echo "  make monitoring        Deploy Prometheus + Grafana monitoring"
	@echo ""
	@echo "Developer Tools:"
	@echo "  make faucet            Deploy token faucet for L1"
	@echo "  make deploy-blockscout Deploy Blockscout block explorer"
	@echo "  make graph-node        Deploy The Graph Node for indexing"
	@echo "  make erpc              Deploy eRPC load balancer"
	@echo ""
	@echo "Validator Manager:"
	@echo "  make init-validator-manager      Build the validator manager tool"
	@echo "  make initialize-validator-manager Deploy and initialize validator manager contract"
	@echo ""
	@echo "Safe Multisig (EXPERIMENTAL):"
	@echo "  make safe-genesis Merge Safe contracts into genesis.json (EXPERIMENTAL)"
	@echo "  make safe         Deploy Safe infrastructure (EXPERIMENTAL)"
	@echo "  make reset-genesis Reset genesis.json to clean state (no Safe contracts)"
	@echo ""
	@echo "Testing:"
	@echo "  make lint             Run ansible-lint and terraform fmt checks"
	@echo "  make validate         Validate all Ansible and Terraform configs"
	@echo "  make test-e2e-l1      Run full L1 E2E test (creates/destroys infra)"
	@echo "  make test-e2e-primary Run full Primary Network E2E test"
	@echo ""
	@echo "Options:"
	@echo "  CLOUD=aws|gcp|azure  (default: aws)"
	@echo "  NETWORK=fuji|mainnet (default: fuji)"
	@echo ""
	@echo "Examples:"
	@echo "  # L1 Deployment"
	@echo "  make infra CLOUD=gcp"
	@echo "  make deploy NETWORK=mainnet"
	@echo "  make upgrade VERSION=1.12.0"
	@echo ""
	@echo "  # Primary Network Validators"
	@echo "  make primary-infra"
	@echo "  make primary-deploy NETWORK=mainnet"
	@echo "  make backup-keys"
	@echo "  make create-snapshot NODE=primary-validator-1"
	@echo "  make list-snapshots"
	@echo "  make prepare-migration NODE=migration-target SNAPSHOT=true"
	@echo "  make migrate-validator SOURCE=primary-validator-1 TARGET=migration-target"
	@echo ""
	@echo "  # Developer Tools"
	@echo "  make faucet CHAIN_ID=xxx EVM_CHAIN_ID=99999 FAUCET_KEY=0x..."
	@echo "  make graph-node CHAIN_ID=xxx NETWORK_NAME=my-l1"
	@echo "  make erpc CHAIN_ID=xxx EVM_CHAIN_ID=99999"
	@echo "  make initialize-validator-manager SUBNET_ID=xxx CHAIN_ID=yyy CONVERSION_TX=zzz PROXY_ADDRESS=0x... EVM_CHAIN_ID=12345"
