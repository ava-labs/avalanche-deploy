output "validator_ips" {
  description = "Public IPs of L1 validator nodes"
  value       = aws_instance.validators[*].public_ip
}

output "validator_private_ips" {
  description = "Private IPs of L1 validator nodes"
  value       = aws_instance.validators[*].private_ip
}

output "primary_validator_ips" {
  description = "Public IPs of Primary Network validators"
  value       = aws_instance.primary_validators[*].public_ip
}

output "primary_validator_private_ips" {
  description = "Private IPs of Primary Network validators"
  value       = aws_instance.primary_validators[*].private_ip
}

output "staking_keys_bucket" {
  description = "S3 bucket for staking key backups"
  value       = local.enable_key_backup ? aws_s3_bucket.staking_keys[0].id : ""
}

output "staking_keys_kms_key_arn" {
  description = "KMS key ARN for staking key encryption"
  value       = local.enable_key_backup ? aws_kms_key.staking_keys[0].arn : ""
}

output "rpc_archive_ips" {
  description = "Public IPs of archive RPC nodes"
  value       = aws_instance.rpc_archive[*].public_ip
}

output "rpc_archive_private_ips" {
  description = "Private IPs of archive RPC nodes"
  value       = aws_instance.rpc_archive[*].private_ip
}

output "rpc_pruned_ips" {
  description = "Public IPs of pruned RPC nodes"
  value       = aws_instance.rpc_pruned[*].public_ip
}

output "rpc_pruned_private_ips" {
  description = "Private IPs of pruned RPC nodes"
  value       = aws_instance.rpc_pruned[*].private_ip
}

output "rpc_ips" {
  description = "Public IPs of all RPC nodes (archive + pruned)"
  value       = concat(aws_instance.rpc_archive[*].public_ip, aws_instance.rpc_pruned[*].public_ip)
}

output "rpc_private_ips" {
  description = "Private IPs of all RPC nodes (archive + pruned)"
  value       = concat(aws_instance.rpc_archive[*].private_ip, aws_instance.rpc_pruned[*].private_ip)
}

output "grafana_url" {
  description = "Grafana dashboard URL"
  value       = "http://${aws_instance.monitoring.public_ip}:3000"
}

output "blockscout_url" {
  description = "Blockscout block explorer URL (on archive RPC node)"
  value       = length(aws_instance.rpc_archive) > 0 ? "http://${aws_instance.rpc_archive[0].public_ip}:4001" : ""
}

output "monitoring_ip" {
  description = "IP of the dedicated monitoring server (Prometheus, Grafana)"
  value       = aws_instance.monitoring.public_ip
}

output "monitoring_private_ip" {
  description = "Private IP of the monitoring server"
  value       = aws_instance.monitoring.private_ip
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "ansible_inventory" {
  description = "Ansible inventory content"
  value       = <<-EOT
[validators]
%{for i, ip in aws_instance.validators[*].public_ip~}
validator-${i + 1} ansible_host=${ip} ansible_user=ubuntu node_type=validator
%{endfor~}

[rpc_archive]
%{for i, inst in aws_instance.rpc_archive~}
rpc-archive-${i + 1} ansible_host=${inst.public_ip} ansible_user=ubuntu node_type=rpc rpc_type=archive
%{endfor~}

[rpc_pruned]
%{for i, inst in aws_instance.rpc_pruned~}
rpc-pruned-${i + 1} ansible_host=${inst.public_ip} ansible_user=ubuntu node_type=rpc rpc_type=pruned
%{endfor~}

[rpc:children]
rpc_archive
rpc_pruned

[primary_validators]
%{for i, inst in aws_instance.primary_validators~}
primary-validator-${i + 1} ansible_host=${inst.public_ip} ansible_user=ubuntu node_type=primary-validator
%{endfor~}

[all_validators:children]
validators
primary_validators

[monitoring]
monitoring-1 ansible_host=${aws_instance.monitoring.public_ip} ansible_user=ubuntu

[all:vars]
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
%{if var.ssh_private_key_file != ""~}
ansible_ssh_private_key_file=${var.ssh_private_key_file}
%{endif~}
EOT
}

# Write inventory file for Ansible
resource "local_file" "ansible_inventory" {
  content  = <<-EOT
[validators]
%{for i, inst in aws_instance.validators~}
validator-${i + 1} ansible_host=${inst.public_ip} private_ip=${inst.private_ip} ansible_user=ubuntu node_type=validator
%{endfor~}

[rpc_archive]
%{for i, inst in aws_instance.rpc_archive~}
rpc-archive-${i + 1} ansible_host=${inst.public_ip} private_ip=${inst.private_ip} ansible_user=ubuntu node_type=rpc rpc_type=archive
%{endfor~}

[rpc_pruned]
%{for i, inst in aws_instance.rpc_pruned~}
rpc-pruned-${i + 1} ansible_host=${inst.public_ip} private_ip=${inst.private_ip} ansible_user=ubuntu node_type=rpc rpc_type=pruned
%{endfor~}

[rpc:children]
rpc_archive
rpc_pruned

[primary_validators]
%{for i, inst in aws_instance.primary_validators~}
primary-validator-${i + 1} ansible_host=${inst.public_ip} private_ip=${inst.private_ip} ansible_user=ubuntu node_type=primary-validator
%{endfor~}

[all_validators:children]
validators
primary_validators

[monitoring]
monitoring-1 ansible_host=${aws_instance.monitoring.public_ip} private_ip=${aws_instance.monitoring.private_ip} ansible_user=ubuntu

[all:vars]
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
%{if var.ssh_private_key_file != ""~}
ansible_ssh_private_key_file=${var.ssh_private_key_file}
%{endif~}
%{if local.enable_key_backup~}
staking_keys_bucket=${aws_s3_bucket.staking_keys[0].id}
staking_keys_kms_arn=${aws_kms_key.staking_keys[0].arn}
%{endif~}
EOT
  filename = "${path.module}/../../ansible/inventory/aws_hosts"
}

# Write env file for create-l1 tool
resource "local_file" "env_file" {
  content  = <<-EOT
# Generated by Terraform
NETWORK=${var.environment}
%{for i, ip in aws_instance.validators[*].public_ip~}
VALIDATOR_${i + 1}_IP=${ip}
%{endfor~}
%{for i, ip in aws_instance.rpc_archive[*].public_ip~}
RPC_ARCHIVE_${i + 1}_IP=${ip}
%{endfor~}
%{for i, ip in aws_instance.rpc_pruned[*].public_ip~}
RPC_PRUNED_${i + 1}_IP=${ip}
%{endfor~}
%{for i, ip in aws_instance.primary_validators[*].public_ip~}
PRIMARY_VALIDATOR_${i + 1}_IP=${ip}
%{endfor~}
%{if local.enable_key_backup~}
STAKING_KEYS_BUCKET=${aws_s3_bucket.staking_keys[0].id}
%{endif~}
EOT
  filename = "${path.module}/../../.env"
}
