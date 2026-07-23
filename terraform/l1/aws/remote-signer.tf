#
# REMOTE SIGNER — optional per-validator KMS keys + IAM for the BLS sidecar
#
# When enabled, provisions ONE KMS key PER VALIDATOR for the BLS key blobs
# and grants the validator instance role Encrypt (setup) + Decrypt (runtime)
# on them. Every validator MUST have a unique BLS key — a shared key would be
# an invalid validator set — so keys are per-validator for isolation and
# individual revocation. The signer runs on the validator hosts via the
# ansible `remote_signer` role, using the instance profile's credentials — no
# static keys. See kubernetes/helm/avalanche-validator/remote-signer.md and
# the signer repo for the deployment side.
#
# The validator IAM role/instance profile is shared with the S3 staking-key
# backup feature; main.tf creates it when either feature is enabled
# (local.enable_validator_role), so this works with
# enable_staking_key_backup = false. All validators share that one role, so
# each can technically decrypt any validator's key — acceptable within a
# single trust domain; per-instance roles would be the next hardening step.
#
# Everything here is self-contained (variable, locals, resources, output) and
# gated — with enable_remote_signer_kms = false (the default) this file adds
# no resources and changes nothing.

variable "enable_remote_signer_kms" {
  description = "Provision per-validator KMS keys + IAM for the BLS remote-signer sidecar. Creates the validator instance role/profile if staking-key backup hasn't already."
  type        = bool
  default     = false
}

locals {
  enable_remote_signer = var.enable_remote_signer_kms && var.validator_count > 0
}

resource "aws_kms_key" "remote_signer" {
  count                   = local.enable_remote_signer ? var.validator_count : 0
  description             = "KMS key for the ${var.name_prefix} validator-${count.index + 1} BLS remote-signer"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-remote-signer-kms-${count.index + 1}"
  })
}

resource "aws_kms_alias" "remote_signer" {
  count         = local.enable_remote_signer ? var.validator_count : 0
  name          = "alias/${var.name_prefix}-remote-signer-${count.index + 1}"
  target_key_id = aws_kms_key.remote_signer[count.index].key_id
}

resource "aws_iam_role_policy" "remote_signer_kms" {
  count = local.enable_remote_signer ? 1 : 0
  name  = "remote-signer-kms-access"
  role  = aws_iam_role.validator[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Decrypt is the only permission the running signer needs; Encrypt is
        # used once by `keytool generate`/`migrate` at setup and can be
        # removed afterward for a strict least-privilege posture.
        Effect   = "Allow"
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"]
        Resource = aws_kms_key.remote_signer[*].arn
      }
    ]
  })
}

# Keyed by ansible inventory hostname (validator-1, validator-2, ...) so the
# map can be passed straight to the ansible role as remote_signer_kms_key_arns.
output "remote_signer_kms_key_arns" {
  description = "Map of validator inventory hostname -> BLS remote-signer KMS key ARN. Pass as remote_signer_kms_key_arns to the ansible role (empty unless enable_remote_signer_kms = true)."
  value       = { for i, k in aws_kms_key.remote_signer : "validator-${i + 1}" => k.arn }
}
