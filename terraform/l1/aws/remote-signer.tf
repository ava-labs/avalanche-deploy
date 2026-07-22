#
# REMOTE SIGNER — optional KMS key + IAM for the BLS signing sidecar
#
# When enabled, provisions a dedicated KMS key for the validator's BLS key
# blob and grants the validator instance role Encrypt (setup) + Decrypt
# (runtime) on it. The signer runs on the validator hosts via the ansible
# `remote-signer` role, using the instance profile's credentials — no static
# keys. See kubernetes/helm/avalanche-validator/remote-signer.md and the
# signer repo for the deployment side.
#
# DEPENDENCY: this reuses the validator IAM role, which only exists when
# enable_staking_key_backup = true (see the IAM section in main.tf). So
# enabling the remote signer requires enable_staking_key_backup = true; the
# local below enforces that by ANDing on local.enable_key_backup.
#
# Everything here is self-contained (variable, locals, resources, output) and
# gated — with enable_remote_signer_kms = false (the default) this file adds
# no resources and changes nothing.

variable "enable_remote_signer_kms" {
  description = "Provision a KMS key + IAM for the BLS remote-signer sidecar. Requires enable_staking_key_backup = true (which creates the validator instance role)."
  type        = bool
  default     = false
}

locals {
  # Reuses local.enable_key_backup from main.tf (validator role + profile).
  enable_remote_signer = var.enable_remote_signer_kms && local.enable_key_backup
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
