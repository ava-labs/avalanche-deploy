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
.PHONY: setup infra deploy status create-l1 safe safe-genesis destroy clean logs

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

monitoring:
	@cd ansible && ansible-playbook playbooks/03-setup-monitoring.yml

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
# Safe Multisig
#
safe:
	@if [ -z "$(CHAIN_ID)" ]; then echo "Usage: make safe CHAIN_ID=xxx EVM_CHAIN_ID=yyy"; exit 1; fi
	@if [ -z "$(EVM_CHAIN_ID)" ]; then echo "Usage: make safe CHAIN_ID=xxx EVM_CHAIN_ID=yyy"; exit 1; fi
	@cd ansible && ansible-playbook playbooks/05-deploy-safe.yml \
		-e "chain_id=$(CHAIN_ID)" \
		-e "evm_chain_id=$(EVM_CHAIN_ID)"

safe-genesis:
	@echo "Merging Safe contracts into genesis.json..."
	@./shared/safe/merge-genesis.sh genesis.json
	@echo "Done! Safe contracts added to genesis.json"

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
	@rm -f tools/create-l1/create-l1
	@echo "Cleaned up generated files."

#
# Help
#
help:
	@echo "Avalanche L1 Deploy"
	@echo ""
	@echo "Quick start:"
	@echo "  make setup        Install dependencies (terraform, ansible, aws-cli)"
	@echo "  make infra        Create cloud infrastructure"
	@echo "  make deploy       Deploy avalanchego to nodes"
	@echo "  make status       Check node sync status"
	@echo "  make create-l1    Build the create-l1 tool"
	@echo "  make destroy      Tear down infrastructure (stops billing!)"
	@echo ""
	@echo "Safe Multisig:"
	@echo "  make safe-genesis Merge Safe contracts into genesis.json (run before create-l1)"
	@echo "  make safe         Deploy Safe infrastructure (run after L1 creation)"
	@echo ""
	@echo "Options:"
	@echo "  CLOUD=aws|gcp|azure  (default: aws)"
	@echo "  NETWORK=fuji|mainnet (default: fuji)"
	@echo ""
	@echo "Example:"
	@echo "  make infra CLOUD=gcp"
	@echo "  make deploy NETWORK=mainnet"
	@echo "  make safe CHAIN_ID=xxx EVM_CHAIN_ID=99999"
