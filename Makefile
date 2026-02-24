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
.PHONY: setup doctor infra infra-plan deploy configure-l1 status create-l1 deploy-blockscout safe reset-l1 destroy clean logs rolling-restart health-checks monitoring faucet upgrade graph-node erpc icm-relayer init-validator-manager initialize-validator-manager primary-infra primary-deploy primary-status backup-keys restore-keys prepare-migration migrate-validator create-snapshot restore-snapshot list-snapshots k8s-help k8s-help-l1 k8s-help-primary k8s-l1 k8s-primary k8s-kind k8s-l1-deploy k8s-l1-wait k8s-l1-create k8s-l1-configure k8s-l1-status k8s-primary-deploy k8s-primary-wait k8s-primary-status k8s-monitoring k8s-icm-relayer k8s-cleanup lint validate-config-layout validate test-unit test-incremental test test-e2e-l1 test-e2e-primary test-e2e-l1-dry test-e2e-primary-dry test-e2e-dry check-primary-cloud help help-l1 help-primary help-all

# Default cloud provider
CLOUD ?= aws
NETWORK ?= fuji
AUTO_APPROVE ?= false
TF_INIT_RETRIES ?= 3
SKIP_TERRAFORM_VALIDATE ?= false
ANSIBLE_INVENTORY = inventory/$(CLOUD)_hosts
ANSIBLE_SYNTAX_INVENTORY ?= ../tests/fixtures/syntax_inventory.ini
L1_CONFIG_DIR ?= configs/l1
PRIMARY_NETWORK_CONFIG_DIR ?= configs/primary-network
L1_GENESIS_FILE ?= $(L1_CONFIG_DIR)/genesis/genesis.json
L1_GENESIS_TEMPLATE ?= $(L1_CONFIG_DIR)/genesis/genesis-clean.json
K8S_DIR ?= kubernetes
K8S_CLUSTER_NAME ?= avalanche-l1
K8S_KIND_IMAGE ?= kindest/node:v1.34.0
K8S_KIND_WORKERS ?= 1
K8S_KIND_MAP_HOST_PORTS ?= false
K8S_KIND_HTTP_PORT ?= 9650
K8S_KIND_STAKING_PORT ?= 9651
K8S_L1_RELEASE ?= l1-validators
K8S_L1_RPC_RELEASE ?= l1-rpc
K8S_PRIMARY_RELEASE ?= primary-validators
K8S_PRIMARY_RPC_RELEASE ?= primary-rpc
K8S_L1_VALIDATOR_VALUES_FILE ?= ./helm/avalanche-validator/values-kind.yaml
K8S_L1_RPC_VALUES_FILE ?= ./helm/avalanche-rpc/values-kind.yaml
K8S_L1_VALIDATOR_REPLICAS ?= 1
K8S_L1_RPC_REPLICAS ?= 1
K8S_PRIMARY_VALIDATOR_REPLICAS ?= 2
K8S_PRIMARY_RPC_REPLICAS ?= 2
K8S_L1_ENV_FILE ?= l1.env
K8S_CHAIN_NAME ?= mychain
K8S_L1_KEY_NAME ?=
export ANSIBLE_LOCAL_TEMP ?= $(CURDIR)/.ansible/tmp
export ANSIBLE_REMOTE_TMP ?= /tmp/.ansible-tmp
export GOCACHE ?= $(CURDIR)/.cache/go-build

#
# Guards
#
check-primary-cloud:
	@if [ "$(CLOUD)" != "aws" ]; then \
		echo "Error: Primary Network workflows are currently supported only on AWS."; \
		echo "Use CLOUD=aws for: primary-infra, primary-deploy, backup-keys, migration, snapshots."; \
		exit 1; \
	fi

#
# Setup
#
setup:
	@echo "Installing dependencies..."
	@which terraform > /dev/null || brew install terraform
	@which ansible > /dev/null || brew install ansible
	@which aws > /dev/null || brew install awscli
	@which jq > /dev/null || brew install jq
	@which go > /dev/null || brew install go
	@which shellcheck > /dev/null || brew install shellcheck
	@which ansible-galaxy > /dev/null && ansible-galaxy collection install -r ansible/requirements.yml || true
	@echo "Done! Run 'make infra' next."

doctor:
	@echo "Checking local development prerequisites..."
	@for cmd in terraform ansible-playbook ansible-lint jq go shellcheck; do \
		if ! command -v $$cmd > /dev/null 2>&1; then \
			echo "Missing dependency: $$cmd"; \
			exit 1; \
		fi; \
	done
	@for f in \
		$(L1_GENESIS_FILE) \
		$(L1_GENESIS_TEMPLATE) \
		$(L1_CONFIG_DIR)/node/validator-node-config.json \
		$(L1_CONFIG_DIR)/node/rpc-node-config.json \
		$(L1_CONFIG_DIR)/chain/validator-chain-config.json \
		$(L1_CONFIG_DIR)/chain/rpc-chain-config.json \
		$(L1_CONFIG_DIR)/chain/rpc-archive-chain-config.json \
		$(L1_CONFIG_DIR)/chain/rpc-pruned-chain-config.json \
		$(PRIMARY_NETWORK_CONFIG_DIR)/node/primary-network-node-config.json \
		$(PRIMARY_NETWORK_CONFIG_DIR)/node/primary-validator-node-config.json; do \
		if [ ! -f "$$f" ]; then \
			echo "Missing config file: $$f"; \
			exit 1; \
		fi; \
	done
	@echo "✓ Prerequisites and config layout look good"

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
	@cd ansible && ansible-playbook -i $(ANSIBLE_INVENTORY) playbooks/01-deploy-nodes.yml -e network=$(NETWORK)
	@echo ""
	@echo "Done! Run 'make status' to check sync progress."

configure-l1:
	@if [ -z "$(SUBNET_ID)" ]; then echo "Usage: make configure-l1 SUBNET_ID=xxx CHAIN_ID=yyy [SKIP_ERPC=true]"; exit 1; fi
	@cd ansible && ansible-playbook -i $(ANSIBLE_INVENTORY) playbooks/02-configure-l1.yml \
		-e subnet_id=$(SUBNET_ID) \
		-e chain_id=$(CHAIN_ID) \
		$(if $(SKIP_ERPC),-e skip_erpc=true,)

reset-l1:
	@echo "Resetting L1 chain data on all nodes..."
	@cd ansible && ansible-playbook -i $(ANSIBLE_INVENTORY) playbooks/00-reset-l1.yml

monitoring:
	@cd ansible && ansible-playbook -i $(ANSIBLE_INVENTORY) playbooks/03-setup-monitoring.yml

rolling-restart:
	@echo "Performing rolling restart of all nodes..."
	@cd ansible && ansible-playbook -i $(ANSIBLE_INVENTORY) playbooks/rolling-restart.yml

health-checks:
	@cd ansible && ansible-playbook -i $(ANSIBLE_INVENTORY) playbooks/health-checks.yml $(if $(CHAIN_ID),-e chain_id=$(CHAIN_ID),)

upgrade:
	@if [ -z "$(VERSION)" ]; then echo "Usage: make upgrade VERSION=1.12.0"; exit 1; fi
	@echo "Upgrading nodes to avalanchego $(VERSION)..."
	@echo "NOTE: subnet-evm is bundled with avalanchego and will be updated automatically."
	@cd ansible && ansible-playbook -i $(ANSIBLE_INVENTORY) playbooks/upgrade-nodes.yml \
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
	@cd tools/create-l1 && go build -o create-l1 .
	@echo "Done! Binary at tools/create-l1/create-l1"

#
# Blockscout Block Explorer
#
deploy-blockscout:
	@if [ -z "$(CHAIN_ID)" ]; then echo "Usage: make deploy-blockscout CHAIN_ID=xxx EVM_CHAIN_ID=yyy [CHAIN_NAME=name]"; exit 1; fi
	@if [ -z "$(EVM_CHAIN_ID)" ]; then echo "Usage: make deploy-blockscout CHAIN_ID=xxx EVM_CHAIN_ID=yyy [CHAIN_NAME=name]"; exit 1; fi
	@echo "Deploying Blockscout block explorer..."
	@cd ansible && ansible-playbook -i $(ANSIBLE_INVENTORY) playbooks/04-deploy-blockscout.yml \
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
	@cd ansible && ansible-playbook -i $(ANSIBLE_INVENTORY) playbooks/06-deploy-faucet.yml \
		-e "l1_chain_id=$(CHAIN_ID)" \
		-e "l1_evm_chain_id=$(EVM_CHAIN_ID)" \
		-e "faucet_private_key=$(FAUCET_KEY)"

#
# The Graph Node
#
graph-node:
	@if [ -z "$(CHAIN_ID)" ]; then echo "Usage: make graph-node CHAIN_ID=xxx [NETWORK_NAME=my-l1]"; exit 1; fi
	@echo "Deploying The Graph Node..."
	@cd ansible && ansible-playbook -i $(ANSIBLE_INVENTORY) playbooks/07-deploy-graph-node.yml \
		-e "l1_chain_id=$(CHAIN_ID)" \
		$(if $(NETWORK_NAME),-e "graph_network_name=$(NETWORK_NAME)",)

erpc:
	@if [ -z "$(CHAIN_ID)" ]; then echo "Usage: make erpc CHAIN_ID=xxx EVM_CHAIN_ID=yyy"; exit 1; fi
	@if [ -z "$(EVM_CHAIN_ID)" ]; then echo "Usage: make erpc CHAIN_ID=xxx EVM_CHAIN_ID=yyy"; exit 1; fi
	@echo "Deploying eRPC load balancer..."
	@cd ansible && ansible-playbook -i $(ANSIBLE_INVENTORY) playbooks/08-deploy-erpc.yml \
		-e "l1_chain_id=$(CHAIN_ID)" \
		-e "l1_evm_chain_id=$(EVM_CHAIN_ID)"

#
# ICM Relayer
#
icm-relayer:
	@if [ -z "$(SUBNET_ID)" ]; then echo "Usage: make icm-relayer SUBNET_ID=xxx CHAIN_ID=yyy RELAYER_KEY=0x..."; exit 1; fi
	@if [ -z "$(CHAIN_ID)" ]; then echo "Usage: make icm-relayer SUBNET_ID=xxx CHAIN_ID=yyy RELAYER_KEY=0x..."; exit 1; fi
	@if [ -z "$(RELAYER_KEY)" ]; then echo "Usage: make icm-relayer SUBNET_ID=xxx CHAIN_ID=yyy RELAYER_KEY=0x..."; exit 1; fi
	@echo "Deploying ICM Relayer..."
	@cd ansible && ansible-playbook -i $(ANSIBLE_INVENTORY) playbooks/16-deploy-icm-relayer.yml \
		-e "l1_subnet_id=$(SUBNET_ID)" \
		-e "l1_chain_id=$(CHAIN_ID)" \
		-e "relayer_private_key=$(RELAYER_KEY)" \
		$(if $(NETWORK),-e "icm_relayer_network=$(NETWORK)",)

#
# Validator Manager
#
init-validator-manager:
	@echo "Building initialize-validator-manager tool..."
	@cd tools/initialize-validator-manager && go build -o initialize-validator-manager .
	@echo "Done! Binary at tools/initialize-validator-manager/initialize-validator-manager"

initialize-validator-manager:
	@if [ -z "$(SUBNET_ID)" ]; then echo "Usage: make initialize-validator-manager SUBNET_ID=xxx CHAIN_ID=yyy CONVERSION_TX=zzz PROXY_ADDRESS=0x... EVM_CHAIN_ID=12345"; exit 1; fi
	@if [ -z "$(CHAIN_ID)" ]; then echo "Usage: make initialize-validator-manager SUBNET_ID=xxx CHAIN_ID=yyy CONVERSION_TX=zzz PROXY_ADDRESS=0x... EVM_CHAIN_ID=12345"; exit 1; fi
	@if [ -z "$(CONVERSION_TX)" ]; then echo "Usage: make initialize-validator-manager SUBNET_ID=xxx CHAIN_ID=yyy CONVERSION_TX=zzz PROXY_ADDRESS=0x... EVM_CHAIN_ID=12345"; exit 1; fi
	@if [ -z "$(PROXY_ADDRESS)" ]; then echo "Usage: make initialize-validator-manager SUBNET_ID=xxx CHAIN_ID=yyy CONVERSION_TX=zzz PROXY_ADDRESS=0x... EVM_CHAIN_ID=12345"; exit 1; fi
	@if [ -z "$(EVM_CHAIN_ID)" ]; then echo "Usage: make initialize-validator-manager SUBNET_ID=xxx CHAIN_ID=yyy CONVERSION_TX=zzz PROXY_ADDRESS=0x... EVM_CHAIN_ID=12345"; exit 1; fi
	@echo "Initializing Validator Manager..."
	@cd ansible && ansible-playbook -i $(ANSIBLE_INVENTORY) playbooks/09-initialize-validator-manager.yml \
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
primary-infra: check-primary-cloud
	@echo "Creating Primary Network validator infrastructure (no L1 validators/RPC)..."
	@cd terraform/$(CLOUD) && terraform init && terraform apply \
		-var="validator_count=0" \
		-var="rpc_archive_count=0" \
		-var="rpc_pruned_count=0" \
		-var="primary_validator_count=1"
	@echo ""
	@echo "Done! Run 'make primary-deploy' next."

primary-deploy: check-primary-cloud
	@echo "Deploying Primary Network validators..."
	@cd ansible && ansible-playbook -i $(ANSIBLE_INVENTORY) playbooks/10-deploy-primary-network.yml -e network=$(NETWORK)
	@echo ""
	@echo "Done! Run 'make primary-status' to check sync progress."

primary-status: check-primary-cloud
	@CLOUD=$(CLOUD) ./scripts/check-primary-sync.sh

backup-keys: check-primary-cloud
	@echo "Backing up staking keys to S3 (L1 + Primary Network validators)..."
	@cd ansible && ansible-playbook -i $(ANSIBLE_INVENTORY) playbooks/11-backup-staking-keys.yml

restore-keys: check-primary-cloud
	@if [ -z "$(SOURCE)" ]; then echo "Usage: make restore-keys SOURCE=primary-validator-1 TARGET_IP=10.0.1.50"; exit 1; fi
	@if [ -z "$(TARGET_IP)" ]; then echo "Usage: make restore-keys SOURCE=primary-validator-1 TARGET_IP=10.0.1.50"; exit 1; fi
	@./scripts/restore-staking-keys.sh $(SOURCE) $(TARGET_IP)

prepare-migration: check-primary-cloud
	@if [ -z "$(NODE)" ]; then echo "Usage: make prepare-migration NODE=migration-target [SNAPSHOT=true] [SNAPSHOT_NAME=latest]"; exit 1; fi
	@echo "Preparing migration node $(NODE)..."
	@cd ansible && ansible-playbook -i $(ANSIBLE_INVENTORY) playbooks/12-prepare-migration-node.yml --limit $(NODE) \
		$(if $(SNAPSHOT),-e "use_snapshot=$(SNAPSHOT)",) \
		$(if $(SNAPSHOT_NAME),-e "snapshot_name=$(SNAPSHOT_NAME)",)

migrate-validator: check-primary-cloud
	@if [ -z "$(SOURCE)" ]; then echo "Usage: make migrate-validator SOURCE=primary-validator-1 TARGET=migration-target"; exit 1; fi
	@if [ -z "$(TARGET)" ]; then echo "Usage: make migrate-validator SOURCE=primary-validator-1 TARGET=migration-target"; exit 1; fi
	@echo "Migrating validator from $(SOURCE) to $(TARGET)..."
	@cd ansible && ansible-playbook -i $(ANSIBLE_INVENTORY) playbooks/13-migrate-validator.yml \
		-e "source_host=$(SOURCE)" \
		-e "target_host=$(TARGET)"

#
# Database Snapshots
#
create-snapshot: check-primary-cloud
	@if [ -z "$(NODE)" ]; then echo "Usage: make create-snapshot NODE=primary-validator-1 [NAME=my-snapshot]"; exit 1; fi
	@echo "Creating database snapshot from $(NODE)..."
	@cd ansible && ansible-playbook -i $(ANSIBLE_INVENTORY) playbooks/14-create-snapshot.yml --limit $(NODE) \
		$(if $(NAME),-e "snapshot_name=$(NAME)",)

restore-snapshot: check-primary-cloud
	@if [ -z "$(TARGET)" ]; then echo "Usage: make restore-snapshot TARGET=migration-target [SNAPSHOT=latest]"; exit 1; fi
	@echo "Restoring snapshot to $(TARGET)..."
	@cd ansible && ansible-playbook -i $(ANSIBLE_INVENTORY) playbooks/15-restore-snapshot.yml --limit $(TARGET) \
		$(if $(SNAPSHOT),-e "snapshot_name=$(SNAPSHOT)",)

list-snapshots: check-primary-cloud
	@./scripts/list-snapshots.sh

#
# Safe Multisig
#
safe:
	$(eval _CHAIN_ID := $(or $(CHAIN_ID),$(shell [ -f l1.env ] && . ./l1.env 2>/dev/null && echo $$CHAIN_ID)))
	$(eval _EVM_CHAIN_ID := $(or $(EVM_CHAIN_ID),$(shell [ -f l1.env ] && . ./l1.env 2>/dev/null && echo $$EVM_CHAIN_ID)))
	$(eval _CHAIN_NAME := $(or $(CHAIN_NAME),$(shell [ -f l1.env ] && . ./l1.env 2>/dev/null && echo $$CHAIN_NAME)))
	@if [ -z "$(_CHAIN_ID)" ] || [ -z "$(_EVM_CHAIN_ID)" ]; then \
		echo "Error: CHAIN_ID/EVM_CHAIN_ID not found. Run 'make create-l1' first or pass explicitly."; exit 1; fi
	@if [ -n "$(AVALANCHE_PRIVATE_KEY)" ]; then \
		echo "Deploying Safe contracts via Singleton Factory..."; \
		RPC_URL=$$(cd terraform/$(CLOUD) && terraform output -json rpc_ips 2>/dev/null | jq -r '.[0]' 2>/dev/null || echo ""); \
		if [ -n "$$RPC_URL" ] && [ "$$RPC_URL" != "null" ]; then \
			RPC_URL="http://$$RPC_URL:9650/ext/bc/$(_CHAIN_ID)/rpc" \
			PRIVATE_KEY="$(AVALANCHE_PRIVATE_KEY)" \
			./scripts/safe/deploy-contracts.sh; \
		else \
			echo "Warning: Could not determine RPC URL from terraform. Skipping contract deployment."; \
			echo "Deploy manually: RPC_URL=... PRIVATE_KEY=... ./scripts/safe/deploy-contracts.sh"; \
		fi; \
	else \
		echo "Note: AVALANCHE_PRIVATE_KEY not set, skipping contract deployment."; \
		echo "Contracts must already be deployed (or deploy manually with scripts/safe/deploy-contracts.sh)."; \
	fi
	@cd ansible && ansible-playbook -i $(ANSIBLE_INVENTORY) playbooks/05-deploy-safe.yml \
		-e "chain_id=$(_CHAIN_ID)" \
		-e "evm_chain_id=$(_EVM_CHAIN_ID)" \
		$(if $(_CHAIN_NAME),-e "safe_chain_name=$(_CHAIN_NAME)" -e "safe_chain_short_name=$(_CHAIN_NAME)")

#
# Kubernetes
#
k8s-help:
	@echo "Kubernetes Workflows"
	@echo ""
	@echo "Use one of:"
	@echo "  make k8s-help-l1"
	@echo "  make k8s-help-primary"
	@echo ""
	@echo "Common wrappers:"
	@echo "  make k8s-kind        # Create local kind cluster"
	@echo "  make k8s-monitoring  # Install/upgrade monitoring chart"
	@echo "  make k8s-icm-relayer # Deploy ICM Relayer for cross-chain messaging"
	@echo "  make k8s-cleanup     # Cleanup releases + optional PVC/kind"

k8s-help-l1:
	@echo "Kubernetes L1 Workflow"
	@echo ""
	@echo "  make k8s-kind"
	@echo "  make k8s-l1-deploy NETWORK=fuji"
	@echo "  make k8s-l1-wait"
	@echo "  platform keys default --name <key-name>"
	@echo "  make k8s-l1-create NETWORK=fuji K8S_CHAIN_NAME=mychain [K8S_L1_KEY_NAME=<key-name>]"
	@echo "  make k8s-l1-configure"
	@echo "  make k8s-l1-status"

k8s-help-primary:
	@echo "Kubernetes Primary Network Workflow"
	@echo ""
	@echo "  make k8s-primary-deploy NETWORK=fuji"
	@echo "  make k8s-primary-wait"
	@echo "  make k8s-primary-status"

k8s-l1: k8s-help-l1
k8s-primary: k8s-help-primary

k8s-kind:
	@if [ "$(K8S_KIND_MAP_HOST_PORTS)" = "true" ]; then \
		cd "$(K8S_DIR)" && ./scripts/create-kind-cluster.sh \
			--name="$(K8S_CLUSTER_NAME)" \
			--image="$(K8S_KIND_IMAGE)" \
			--workers="$(K8S_KIND_WORKERS)" \
			--map-host-ports \
			--http-port="$(K8S_KIND_HTTP_PORT)" \
			--staking-port="$(K8S_KIND_STAKING_PORT)"; \
	else \
		cd "$(K8S_DIR)" && ./scripts/create-kind-cluster.sh \
			--name="$(K8S_CLUSTER_NAME)" \
			--image="$(K8S_KIND_IMAGE)" \
			--workers="$(K8S_KIND_WORKERS)" \
			--no-map-host-ports; \
	fi

k8s-l1-deploy:
	@cd "$(K8S_DIR)" && helm upgrade --install "$(K8S_L1_RELEASE)" ./helm/avalanche-validator \
		-f "$(K8S_L1_VALIDATOR_VALUES_FILE)" \
		--set "l1_validator_replicas=$(K8S_L1_VALIDATOR_REPLICAS)" \
		--set "network=$(NETWORK)"
	@cd "$(K8S_DIR)" && helm upgrade --install "$(K8S_L1_RPC_RELEASE)" ./helm/avalanche-rpc \
		-f "$(K8S_L1_RPC_VALUES_FILE)" \
		--set "l1_rpc_replicas=$(K8S_L1_RPC_REPLICAS)" \
		--set "network=$(NETWORK)"

k8s-l1-wait:
	@cd "$(K8S_DIR)" && ./scripts/wait-for-sync.sh --release="$(K8S_L1_RELEASE)"

k8s-l1-create:
	@cd "$(K8S_DIR)" && \
		if [ -n "$(K8S_L1_KEY_NAME)" ]; then \
			./scripts/create-l1.sh \
				--release="$(K8S_L1_RELEASE)" \
				--network="$(NETWORK)" \
				--chain-name="$(K8S_CHAIN_NAME)" \
				--output="$(K8S_L1_ENV_FILE)" \
				--key-name="$(K8S_L1_KEY_NAME)"; \
		else \
			./scripts/create-l1.sh \
				--release="$(K8S_L1_RELEASE)" \
				--network="$(NETWORK)" \
				--chain-name="$(K8S_CHAIN_NAME)" \
				--output="$(K8S_L1_ENV_FILE)"; \
		fi

k8s-l1-configure:
	@cd "$(K8S_DIR)" && ./scripts/configure-l1.sh \
		--release="$(K8S_L1_RELEASE)" \
		--env="$(K8S_L1_ENV_FILE)"

k8s-l1-status:
	@cd "$(K8S_DIR)" && ./scripts/status.sh --release="$(K8S_L1_RELEASE)"

k8s-primary-deploy:
	@cd "$(K8S_DIR)" && helm upgrade --install "$(K8S_PRIMARY_RELEASE)" ./helm/primary-network-validator \
		--set "primary_validator_replicas=$(K8S_PRIMARY_VALIDATOR_REPLICAS)" \
		--set "network=$(NETWORK)"
	@cd "$(K8S_DIR)" && helm upgrade --install "$(K8S_PRIMARY_RPC_RELEASE)" ./helm/primary-network-rpc \
		--set "primary_rpc_replicas=$(K8S_PRIMARY_RPC_REPLICAS)" \
		--set "network=$(NETWORK)"

k8s-primary-wait:
	@cd "$(K8S_DIR)" && ./scripts/wait-for-sync.sh --release="$(K8S_PRIMARY_RELEASE)"

k8s-primary-status:
	@cd "$(K8S_DIR)" && ./scripts/status.sh --release="$(K8S_PRIMARY_RELEASE)"

k8s-monitoring:
	@cd "$(K8S_DIR)" && helm upgrade --install monitoring ./helm/monitoring

k8s-icm-relayer:
	@if [ -z "$(SUBNET_ID)" ]; then echo "Usage: make k8s-icm-relayer SUBNET_ID=xxx CHAIN_ID=yyy RELAYER_KEY=0x..."; exit 1; fi
	@if [ -z "$(CHAIN_ID)" ]; then echo "Usage: make k8s-icm-relayer SUBNET_ID=xxx CHAIN_ID=yyy RELAYER_KEY=0x..."; exit 1; fi
	@if [ -z "$(RELAYER_KEY)" ]; then echo "Usage: make k8s-icm-relayer SUBNET_ID=xxx CHAIN_ID=yyy RELAYER_KEY=0x..."; exit 1; fi
	@cd "$(K8S_DIR)" && helm upgrade --install icm-relayer ./helm/icm-relayer \
		--set "l1.subnetId=$(SUBNET_ID)" \
		--set "l1.blockchainId=$(CHAIN_ID)" \
		--set "relayerPrivateKey=$(RELAYER_KEY)" \
		--set "network=$(NETWORK)"

k8s-cleanup:
	@cd "$(K8S_DIR)" && ./scripts/cleanup.sh

#
# Testing & Validation
#
lint:
	@echo "Running linters..."
	@mkdir -p "$(ANSIBLE_LOCAL_TEMP)"
	@which ansible-lint > /dev/null 2>&1 || { \
		echo "ansible-lint not found. Installing..."; \
		if command -v brew > /dev/null 2>&1; then \
			brew install ansible-lint; \
		elif command -v pipx > /dev/null 2>&1; then \
			pipx install ansible-lint; \
		else \
			pip3 install --user ansible-lint; \
		fi; \
	}
	@cd ansible && ansible-lint playbooks/*.yml
	@echo ""
	@echo "Checking Terraform format..."
	@cd terraform/aws && terraform fmt -check -recursive
	@cd terraform/gcp && terraform fmt -check -recursive
	@cd terraform/azure && terraform fmt -check -recursive
	@echo ""
	@echo "Checking shell scripts..."
	@if command -v shellcheck > /dev/null 2>&1; then \
		for f in $$(find scripts tests kubernetes/scripts -type f -name '*.sh' | sort); do bash -n "$$f"; shellcheck -S error "$$f"; done; \
	else \
		echo "shellcheck not found. Running syntax checks only."; \
		for f in $$(find scripts tests kubernetes/scripts -type f -name '*.sh' | sort); do bash -n "$$f"; done; \
	fi
	@echo "Done!"

validate-config-layout:
	@echo "Validating configuration layout..."
	@for f in \
		$(L1_GENESIS_FILE) \
		$(L1_GENESIS_TEMPLATE) \
		$(L1_CONFIG_DIR)/node/validator-node-config.json \
		$(L1_CONFIG_DIR)/node/rpc-node-config.json \
		$(L1_CONFIG_DIR)/chain/validator-chain-config.json \
		$(L1_CONFIG_DIR)/chain/rpc-chain-config.json \
		$(L1_CONFIG_DIR)/chain/rpc-archive-chain-config.json \
		$(L1_CONFIG_DIR)/chain/rpc-pruned-chain-config.json \
		$(PRIMARY_NETWORK_CONFIG_DIR)/node/primary-network-node-config.json \
		$(PRIMARY_NETWORK_CONFIG_DIR)/node/primary-validator-node-config.json; do \
		if [ ! -f "$$f" ]; then \
			echo "Missing config file: $$f"; \
			exit 1; \
		fi; \
	done
	@for f in $(L1_CONFIG_DIR)/genesis/*.json $(L1_CONFIG_DIR)/node/*.json $(L1_CONFIG_DIR)/chain/*.json $(PRIMARY_NETWORK_CONFIG_DIR)/node/*.json; do \
		jq -e . "$$f" > /dev/null || { echo "Invalid JSON: $$f"; exit 1; }; \
	done
	@echo "✓ Config files are present and valid JSON"

validate: validate-config-layout
	@echo "Validating Ansible playbooks..."
	@mkdir -p "$(ANSIBLE_LOCAL_TEMP)"
	@cd ansible && for f in playbooks/*.yml; do \
		echo "  Checking $$f..."; \
		ansible-playbook --syntax-check -i "$(ANSIBLE_SYNTAX_INVENTORY)" "$$f" > /dev/null || exit 1; \
	done
	@echo "✓ All Ansible playbooks valid"
	@if [ "$(SKIP_TERRAFORM_VALIDATE)" = "true" ]; then \
		echo ""; \
		echo "Skipping Terraform validation (SKIP_TERRAFORM_VALIDATE=true)"; \
	else \
		echo ""; \
		echo "Validating Terraform configurations..."; \
		set -e; \
		validate_terraform() { \
			local dir="$$1"; \
			local label="$$2"; \
			local attempt=1; \
			while [ $$attempt -le $(TF_INIT_RETRIES) ]; do \
				if (cd "$$dir" && terraform init -backend=false -input=false > /dev/null && terraform validate); then \
					echo "✓ $$label terraform valid"; \
					return 0; \
				fi; \
				if [ $$attempt -lt $(TF_INIT_RETRIES) ]; then \
					echo "Retrying $$label terraform validation ($$attempt/$(TF_INIT_RETRIES))..."; \
					sleep 2; \
				fi; \
				attempt=$$((attempt + 1)); \
			done; \
			echo "✗ $$label terraform validation failed after $(TF_INIT_RETRIES) attempts"; \
			return 1; \
		}; \
		validate_terraform terraform/aws AWS; \
		validate_terraform terraform/gcp GCP; \
		validate_terraform terraform/azure Azure; \
	fi
	@echo ""
	@echo "All validations passed!"

test-e2e-l1:
	@echo "Running L1 E2E test..."
	@./tests/e2e-l1.sh

test-e2e-primary:
	@echo "Running Primary Network E2E test..."
	@./tests/e2e-primary-network.sh

test-e2e-l1-dry:
	@echo "Running L1 E2E dry-run..."
	@./tests/e2e-l1.sh --dry-run

test-e2e-primary-dry:
	@echo "Running Primary Network E2E dry-run..."
	@./tests/e2e-primary-network.sh --dry-run

test-e2e-dry: test-e2e-l1-dry test-e2e-primary-dry
	@echo "✓ E2E dry-run checks passed"

test-unit:
	@echo "Running unit tests..."
	@cd tools/create-l1 && go test ./...
	@cd tools/initialize-validator-manager && go test ./...
	@cd tools/initialize-validator-manager/cmd/init_valset && go test ./...
	@echo "✓ Unit tests passed"

test-incremental: lint validate test-unit test-e2e-dry
	@echo "✓ Incremental checks passed"

test: test-incremental
	@echo "✓ Default test suite passed"

#
# Cleanup
#
destroy:
	@echo "Destroying $(CLOUD) infrastructure..."
	@cd terraform/$(CLOUD) && terraform destroy $(if $(filter true,$(AUTO_APPROVE)),-auto-approve,)
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
	@echo "Avalanche Deploy"
	@echo ""
	@echo "Primary workflows:"
	@echo "  1) L1 setup + add-ons (AWS/GCP/Azure)"
	@echo "  2) Primary Network validator ops (AWS-only)"
	@echo "  3) Kubernetes workflows (L1 + Primary Network)"
	@echo ""
	@echo "Run one of:"
	@echo "  make help-l1"
	@echo "  make help-primary"
	@echo "  make k8s-help"
	@echo "  make help-all         # full command reference"
	@echo ""
	@echo "Guardrails:"
	@echo "  make doctor"
	@echo "  make test-incremental"

help-l1:
	@echo "L1 Workflow (Setup + Add-ons)"
	@echo ""
	@echo "Core flow:"
	@echo "  make setup"
	@echo "  make infra CLOUD=aws|gcp|azure"
	@echo "  make deploy CLOUD=aws|gcp|azure NETWORK=fuji|mainnet"
	@echo "  make create-l1"
	@echo "  make configure-l1 CLOUD=<provider> SUBNET_ID=... CHAIN_ID=...  (includes eRPC)"
	@echo "  make status CLOUD=<provider>"
	@echo ""
	@echo "Add-ons:"
	@echo "  make deploy-blockscout CHAIN_ID=... EVM_CHAIN_ID=... [CHAIN_NAME=...]"
	@echo "  make faucet CHAIN_ID=... EVM_CHAIN_ID=... FAUCET_KEY=0x..."
	@echo "  make graph-node CHAIN_ID=... [NETWORK_NAME=...]"
	@echo "  make erpc CHAIN_ID=... EVM_CHAIN_ID=...          (standalone re-deploy)"
	@echo "  make icm-relayer SUBNET_ID=... CHAIN_ID=... RELAYER_KEY=0x..."
	@echo "  make safe [CHAIN_ID=... EVM_CHAIN_ID=...]  (auto-detects from l1.env)"
	@echo ""
	@echo "Ops:"
	@echo "  make monitoring | make health-checks | make rolling-restart | make upgrade VERSION=x.y.z"
	@echo ""
	@echo "Kubernetes equivalent:"
	@echo "  make k8s-help-l1"

help-primary:
	@echo "Primary Network Workflow (AWS-only)"
	@echo ""
	@echo "Core flow:"
	@echo "  make setup"
	@echo "  make primary-infra CLOUD=aws"
	@echo "  make primary-deploy CLOUD=aws NETWORK=fuji|mainnet"
	@echo "  make primary-status CLOUD=aws"
	@echo ""
	@echo "Maintenance + security:"
	@echo "  make backup-keys CLOUD=aws"
	@echo "  make restore-keys CLOUD=aws SOURCE=... TARGET_IP=..."
	@echo "  make create-snapshot CLOUD=aws NODE=..."
	@echo "  make list-snapshots CLOUD=aws"
	@echo "  make restore-snapshot CLOUD=aws TARGET=... [SNAPSHOT=...]"
	@echo "  make prepare-migration CLOUD=aws NODE=... [SNAPSHOT=true]"
	@echo "  make migrate-validator CLOUD=aws SOURCE=... TARGET=..."
	@echo ""
	@echo "Kubernetes equivalent:"
	@echo "  make k8s-help-primary"

help-all:
	@echo "Avalanche Deploy - Full Command Reference"
	@echo ""
	@echo "Quick start (L1):"
	@echo "  make setup        Install dependencies (terraform, ansible, aws-cli, jq, go, shellcheck)"
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
	@echo "Kubernetes Wrappers:"
	@echo "  make k8s-help           Kubernetes wrapper overview"
	@echo "  make k8s-kind           Create kind cluster"
	@echo "  make k8s-l1-deploy      Install/upgrade L1 validator + RPC charts"
	@echo "  make k8s-l1-wait        Wait for L1 validator sync"
	@echo "  make k8s-l1-create      Create L1 from Kubernetes validators"
	@echo "  make k8s-l1-configure   Configure L1 tracking on validators"
	@echo "  make k8s-l1-status      Check L1 release status"
	@echo "  make k8s-primary-deploy Install/upgrade Primary validator + RPC charts"
	@echo "  make k8s-primary-wait   Wait for Primary validator sync"
	@echo "  make k8s-primary-status Check Primary release status"
	@echo "  make k8s-monitoring     Install/upgrade monitoring chart"
	@echo "  make k8s-icm-relayer    Deploy ICM Relayer for cross-chain messaging"
	@echo "  make k8s-cleanup        Cleanup Kubernetes resources"
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
	@echo "  make icm-relayer       Deploy ICM Relayer for cross-chain messaging"
	@echo ""
	@echo "Validator Manager:"
	@echo "  make init-validator-manager      Build the validator manager tool"
	@echo "  make initialize-validator-manager Deploy and initialize validator manager contract"
	@echo ""
	@echo "Safe Multisig:"
	@echo "  make safe         Deploy Safe contracts + infrastructure (auto-detects chain from l1.env)"
	@echo ""
	@echo "Testing:"
	@echo "  make lint             Run ansible-lint and terraform fmt checks"
	@echo "  make doctor           Verify local prerequisites and config layout"
	@echo "  make validate-config-layout Verify config files exist and are valid JSON"
	@echo "  make validate         Validate all Ansible and Terraform configs"
	@echo "  make test-unit        Run Go unit tests for local tools"
	@echo "  make test-e2e-dry     Run both E2E scripts in dry-run mode (no infra changes)"
	@echo "  make test-incremental Run lint + validate + unit tests + E2E dry-run"
	@echo "  make test             Alias for test-incremental"
	@echo "  make test-e2e-l1      Run full L1 E2E test (creates/destroys infra)"
	@echo "  make test-e2e-primary Run full Primary Network E2E test"
	@echo ""
	@echo "Options:"
	@echo "  CLOUD=aws|gcp|azure  (default: aws)"
	@echo "  NETWORK=fuji|mainnet (default: fuji)"
	@echo "  AUTO_APPROVE=true    Auto-confirm terraform destroy (use with care)"
	@echo "  TF_INIT_RETRIES=3    Terraform init/validate retry count"
	@echo "  SKIP_ERPC=true           Skip automatic eRPC deployment during configure-l1"
	@echo "  SKIP_TERRAFORM_VALIDATE=true Skip Terraform validation (air-gapped/local only)"
	@echo "  K8S_DIR=kubernetes   Kubernetes working directory"
	@echo "  K8S_KIND_IMAGE=...   kind node image for make k8s-kind"
	@echo "  K8S_KIND_WORKERS=1   worker count for make k8s-kind"
	@echo "  K8S_KIND_MAP_HOST_PORTS=false map host ports when creating kind cluster"
	@echo "  K8S_KIND_HTTP_PORT   host HTTP API port for make k8s-kind"
	@echo "  K8S_KIND_STAKING_PORT host staking/P2P port for make k8s-kind"
	@echo "  K8S_L1_VALIDATOR_VALUES_FILE values file for make k8s-l1-deploy validator chart"
	@echo "  K8S_L1_RPC_VALUES_FILE values file for make k8s-l1-deploy rpc chart"
	@echo "  K8S_L1_KEY_NAME      optional platform-cli key for make k8s-l1-create"
	@echo "  K8S_* variables      Release names/replicas for k8s wrapper targets"
	@echo ""
	@echo "Examples:"
	@echo "  # L1 Deployment"
	@echo "  make infra CLOUD=gcp"
	@echo "  make deploy NETWORK=mainnet"
	@echo "  make upgrade VERSION=1.12.0"
	@echo ""
	@echo "  # Primary Network Validators"
	@echo "  make primary-infra CLOUD=aws"
	@echo "  make primary-deploy CLOUD=aws NETWORK=mainnet"
	@echo "  make backup-keys CLOUD=aws"
	@echo "  make create-snapshot CLOUD=aws NODE=primary-validator-1"
	@echo "  make list-snapshots CLOUD=aws"
	@echo "  make prepare-migration CLOUD=aws NODE=migration-target SNAPSHOT=true"
	@echo "  make migrate-validator CLOUD=aws SOURCE=primary-validator-1 TARGET=migration-target"
	@echo ""
	@echo "  # Developer Tools"
	@echo "  make faucet CHAIN_ID=xxx EVM_CHAIN_ID=99999 FAUCET_KEY=0x..."
	@echo "  make graph-node CHAIN_ID=xxx NETWORK_NAME=my-l1"
	@echo "  make erpc CHAIN_ID=xxx EVM_CHAIN_ID=99999"
	@echo "  make icm-relayer SUBNET_ID=xxx CHAIN_ID=yyy RELAYER_KEY=0x..."
	@echo "  make initialize-validator-manager SUBNET_ID=xxx CHAIN_ID=yyy CONVERSION_TX=zzz PROXY_ADDRESS=0x... EVM_CHAIN_ID=12345"
