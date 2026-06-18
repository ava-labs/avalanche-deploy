#!/usr/bin/env bash
# scripts/e2e-aws.sh
#
# End-to-end test of the aws-kms backend on REAL AWS infrastructure, driven
# entirely by the AWS CLI:
#
#   1. provision   — KMS key, IAM role + instance profile, key pair, security
#                    group, and an EC2 instance (the "node")
#   2. deploy/run  — ship this repo to the instance, build the signer, generate
#                    a KMS-encrypted BLS key, start the signer, then start
#                    avalanchego pointed at it (--staking-rpc-signer-endpoint)
#   3. validate    — confirm warp + proof-of-possession signing works end to end
#                    (see scripts/e2e/remote-setup.sh)
#   4. teardown    — delete every resource created (runs even on failure)
#
# This COSTS money (a running EC2 instance) and needs working AWS credentials
# with permission to manage KMS / EC2 / IAM. Nothing here runs unless you invoke
# it. Everything created is tagged `e2e-remote-signer=<run-id>` for easy auditing.
#
# Usage:
#   AWS_REGION=us-east-1 ./scripts/e2e-aws.sh
#   E2E_KEEP=1 ./scripts/e2e-aws.sh        # skip teardown (debug; clean up yourself!)
#
# Requires: aws CLI v2, jq, ssh/scp, git.

set -o errexit
set -o nounset
set -o pipefail

# ── Config (override via env) ──────────────────────────────────────────────────
REGION="${AWS_REGION:-us-east-1}"
INSTANCE_TYPE="${E2E_INSTANCE_TYPE:-t3.xlarge}"          # 4 vCPU / 16 GB — headroom for `go build` + avalanchego
NETWORK_ID="${E2E_NETWORK_ID:-fuji}"                     # node boots + exposes info API without full bootstrap
AVALANCHEGO_VERSION="${AVALANCHEGO_VERSION:-v1.14.0}"    # must support --staking-rpc-signer-endpoint
SSH_USER="ubuntu"
RUN_ID="${E2E_RUN_ID:-rs-e2e-$(date +%Y%m%d-%H%M%S)-$$}"
TAG_KEY="e2e-remote-signer"
WORKDIR="$(mktemp -d)"
KEYFILE="$WORKDIR/$RUN_ID.pem"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Resource handles, filled in as we go (used by teardown).
KEY_ID="" ; KEY_ARN="" ; ROLE_NAME="" ; PROFILE_NAME="" ; SG_ID="" ; KP_NAME="" ; INSTANCE_ID=""

log()  { printf '\033[1;34m[e2e %s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
fail() { printf '\033[1;31m[e2e FAIL]\033[0m %s\n' "$*" >&2; exit 1; }
aws()  { command aws --region "$REGION" --output json "$@"; }

# ── Teardown (runs on every exit) ──────────────────────────────────────────────
teardown() {
  local code=$?
  if [[ "${E2E_KEEP:-0}" == "1" ]]; then
    log "E2E_KEEP=1 — leaving resources up. Clean up manually (tag $TAG_KEY=$RUN_ID)."
    log "  instance=$INSTANCE_ID  key=$KEY_ARN  sg=$SG_ID  role=$ROLE_NAME  keypair=$KP_NAME"
    return
  fi
  log "tearing down (run-id $RUN_ID) …"
  [[ -n "$INSTANCE_ID" ]] && { aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" >/dev/null 2>&1 || true
                               aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" 2>/dev/null || true; }
  if [[ -n "$PROFILE_NAME" ]]; then
    aws iam remove-role-from-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE_NAME" >/dev/null 2>&1 || true
    aws iam delete-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null 2>&1 || true
  fi
  if [[ -n "$ROLE_NAME" ]]; then
    aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name kms-access >/dev/null 2>&1 || true
    aws iam delete-role --role-name "$ROLE_NAME" >/dev/null 2>&1 || true
  fi
  [[ -n "$SG_ID" ]]   && aws ec2 delete-security-group --group-id "$SG_ID" >/dev/null 2>&1 || true
  [[ -n "$KP_NAME" ]] && aws ec2 delete-key-pair --key-name "$KP_NAME" >/dev/null 2>&1 || true
  # KMS keys cannot be deleted instantly — schedule deletion at the minimum 7-day window.
  [[ -n "$KEY_ID" ]]  && aws kms schedule-key-deletion --key-id "$KEY_ID" --pending-window-in-days 7 >/dev/null 2>&1 || true
  rm -rf "$WORKDIR"
  log "teardown done (KMS key $KEY_ID scheduled for deletion in 7 days)."
  exit $code
}
trap teardown EXIT

# ── Preflight ───────────────────────────────────────────────────────────────────
for bin in aws jq ssh scp git; do command -v "$bin" >/dev/null || fail "missing dependency: $bin"; done
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)" || fail "no working AWS credentials"
log "account=$ACCOUNT region=$REGION run-id=$RUN_ID"

# ── 1. Provision ─────────────────────────────────────────────────────────────────
log "creating KMS key …"
KEY_ARN="$(aws kms create-key --description "remote-signer e2e $RUN_ID" \
  --key-usage ENCRYPT_DECRYPT --key-spec SYMMETRIC_DEFAULT \
  --tags TagKey="$TAG_KEY",TagValue="$RUN_ID" --query KeyMetadata.Arn --output text)"
KEY_ID="${KEY_ARN##*/}"
log "  KMS key: $KEY_ARN"

log "creating IAM role + instance profile …"
ROLE_NAME="$RUN_ID-role" ; PROFILE_NAME="$RUN_ID-profile"
aws iam create-role --role-name "$ROLE_NAME" \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
  --tags Key="$TAG_KEY",Value="$RUN_ID" >/dev/null
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name kms-access \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"kms:Encrypt\",\"kms:Decrypt\"],\"Resource\":\"$KEY_ARN\"}]}" >/dev/null
aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null
aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE_NAME" >/dev/null
sleep 12   # IAM instance-profile propagation

log "creating key pair + security group …"
KP_NAME="$RUN_ID-key"
aws ec2 create-key-pair --key-name "$KP_NAME" --query KeyMaterial --output text > "$KEYFILE"
chmod 600 "$KEYFILE"
MY_IP="$(curl -fsS https://checkip.amazonaws.com)/32"
VPC_ID="$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)"
SG_ID="$(aws ec2 create-security-group --group-name "$RUN_ID-sg" --description "remote-signer e2e $RUN_ID" \
  --vpc-id "$VPC_ID" --query GroupId --output text)"
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 22 --cidr "$MY_IP" >/dev/null
# The signer (50051) and avalanchego API (9650) stay on loopback — no inbound rules needed.

log "launching EC2 instance ($INSTANCE_TYPE, Ubuntu 22.04) …"
AMI_ID="$(aws ssm get-parameter \
  --name /aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
  --query Parameter.Value --output text)"
INSTANCE_ID="$(aws ec2 run-instances --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" \
  --key-name "$KP_NAME" --security-group-ids "$SG_ID" \
  --iam-instance-profile Name="$PROFILE_NAME" \
  --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=40,VolumeType=gp3}' \
  --tag-specifications "ResourceType=instance,Tags=[{Key=$TAG_KEY,Value=$RUN_ID},{Key=Name,Value=$RUN_ID}]" \
  --query 'Instances[0].InstanceId' --output text)"
log "  instance: $INSTANCE_ID — waiting for it to come up …"
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
HOST="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
log "  public ip: $HOST"

# ── 2. Deploy ────────────────────────────────────────────────────────────────────
SSH="ssh -i $KEYFILE -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
log "waiting for SSH …"
for i in $(seq 1 30); do $SSH "$SSH_USER@$HOST" true 2>/dev/null && break; sleep 10
  [[ $i == 30 ]] && fail "SSH never came up"; done

log "shipping repo (git archive of HEAD) …"
git -C "$REPO_ROOT" archive --format=tar.gz -o "$WORKDIR/repo.tgz" HEAD
scp -i "$KEYFILE" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "$WORKDIR/repo.tgz" "$SSH_USER@$HOST:/tmp/repo.tgz"
$SSH "$SSH_USER@$HOST" 'mkdir -p ~/remote-signer && tar -xzf /tmp/repo.tgz -C ~/remote-signer'

# ── 3. Run + validate (all node-side logic lives in remote-setup.sh) ─────────────
log "running setup + validation on the instance …"
if $SSH "$SSH_USER@$HOST" \
     "cd ~/remote-signer && AWS_REGION=$REGION KMS_KEY_ARN=$KEY_ARN NETWORK_ID=$NETWORK_ID AVALANCHEGO_VERSION=$AVALANCHEGO_VERSION bash scripts/e2e/remote-setup.sh"
then
  log "✅ E2E PASSED — warp + proof-of-possession signing verified end to end."
else
  fail "❌ E2E FAILED — see the instance output above."
fi
# teardown runs via the EXIT trap
