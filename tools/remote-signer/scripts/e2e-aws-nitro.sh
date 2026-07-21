#!/usr/bin/env bash
# E2E test for the aws-nitro backend on a reused Nitro-enabled EC2 host.
#
# Prerequisites: Amazon Linux 2023, Nitro Enclaves, nitro-cli, docker, IAM profile
# with kms:Encrypt/kms:Decrypt, KMS key policy allowing the instance role (and PCR0
# if attestation is enforced). See docs/aws-nitro.md.
#
# Usage:
#   export AWS_PROFILE=remoteE2E
#   AWS_REGION=us-east-2 \
#   E2E_KMS_KEY_ARN=arn:aws:kms:...:key/... \
#   E2E_HOST=1.2.3.4 E2E_SSH_KEY=~/.ssh/key.pem E2E_SSH_USER=ec2-user \
#     ./scripts/e2e-aws-nitro.sh
set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=e2e/common.sh
source "$SCRIPT_DIR/e2e/common.sh"

AWS_REGION="${AWS_REGION:-us-east-2}"
: "${E2E_KMS_KEY_ARN:?E2E_KMS_KEY_ARN required}"
SSH_USER="${E2E_SSH_USER:-ec2-user}"

e2e_init_common
for bin in jq ssh scp git; do command -v "$bin" >/dev/null || e2e_fail "missing dependency: $bin"; done
e2e_require_host_reuse
e2e_log "backend=aws-nitro host=$HOST region=$AWS_REGION run-id=$RUN_ID"

ssh="$(e2e_ssh_cmd)"
e2e_wait_ssh "$ssh"
e2e_ship_repo "$ssh"

nitro_env="AWS_REGION=$AWS_REGION KMS_KEY_ARN=$E2E_KMS_KEY_ARN"
[[ -n "${E2E_EIF_PATH:-}" ]] && nitro_env="$nitro_env E2E_EIF_PATH=$E2E_EIF_PATH"
[[ -n "${E2E_SKIP_EIF_REBUILD:-}" ]] && nitro_env="$nitro_env E2E_SKIP_EIF_REBUILD=$E2E_SKIP_EIF_REBUILD"
[[ -n "${E2E_ENCLAVE_CID:-}" ]] && nitro_env="$nitro_env E2E_ENCLAVE_CID=$E2E_ENCLAVE_CID"
[[ -n "${E2E_ALLOW_EIF_OVERWRITE:-}" ]] && nitro_env="$nitro_env E2E_ALLOW_EIF_OVERWRITE=$E2E_ALLOW_EIF_OVERWRITE"

e2e_run_remote "$ssh" "remote-setup-nitro.sh" "$nitro_env"
rm -rf "$WORKDIR"
