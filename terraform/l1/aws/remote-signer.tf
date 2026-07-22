#
# REMOTE SIGNER — optional KMS key + IAM for the BLS signing sidecar
#
# When enabled, provisions a dedicated KMS key for the validator's BLS key
# blob and grants the validator instance role Encrypt (setup) + Decrypt
# (runtime) on it. The signer runs on the validator hosts via the ansible
# `remote_signer` role, using the instance profile's credentials — no static
# keys. See kubernetes/helm/avalanche-validator/remote-signer.md and the
# signer repo for the deployment side.
#
# The validator IAM role/instance profile is shared with the S3 staking-key
# backup feature; main.tf creates it when either feature is enabled
# (local.enable_validator_role), so this works with
# enable_staking_key_backup = false.
#
# Everything here is self-contained (variable, locals, resources, output) and
# gated — with enable_remote_signer_kms = false (the default) this file adds
# no resources and changes nothing.

variable "enable_remote_signer_kms" {
  description = "Provision a KMS key + IAM for the BLS remote-signer sidecar. Creates the validator instance role/profile if staking-key backup hasn't already."
  type        = bool
  default     = false
}

locals {
  enable_remote_signer = var.enable_remote_signer_kms && var.validator_count > 0
}

resource "aws_kms_key" "remote_signer" {
  count                   = local.enable_remote_signer ? 1 : 0
  description             = "KMS key for the ${var.name_prefix} validator BLS remote-signer"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-remote-signer-kms"
  })
}

resource "aws_kms_alias" "remote_signer" {
  count         = local.enable_remote_signer ? 1 : 0
  name          = "alias/${var.name_prefix}-remote-signer"
  target_key_id = aws_kms_key.remote_signer[0].key_id
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
        Resource = aws_kms_key.remote_signer[0].arn
      }
    ]
  })
}

output "remote_signer_kms_key_arn" {
  description = "ARN of the BLS remote-signer KMS key — set as remote_signer_aws.kms_key_id in the ansible role (empty unless enable_remote_signer_kms = true)."
  value       = local.enable_remote_signer ? aws_kms_key.remote_signer[0].arn : ""
}
