output "primary_validator_ips" {
  description = "Public IPs of Primary Network validators"
  value       = aws_instance.primary_validators[*].public_ip
}

output "primary_validator_private_ips" {
  description = "Private IPs of Primary Network validators"
  value       = aws_instance.primary_validators[*].private_ip
}

output "monitoring_ip" {
  description = "IP of the dedicated monitoring server (Prometheus, Grafana)"
  value       = aws_instance.monitoring.public_ip
}

output "monitoring_private_ip" {
  description = "Private IP of the monitoring server"
  value       = aws_instance.monitoring.private_ip
}

output "staking_keys_bucket" {
  description = "S3 bucket for staking key backups"
  value       = local.enable_key_backup ? aws_s3_bucket.staking_keys[0].id : ""
}

output "staking_keys_kms_key_arn" {
  description = "KMS key ARN for staking key encryption"
  value       = local.enable_key_backup ? aws_kms_key.staking_keys[0].arn : ""
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "grafana_url" {
  description = "Grafana dashboard URL"
  value       = "http://${aws_instance.monitoring.public_ip}:3000"
}

# Write inventory file for Ansible
resource "local_file" "ansible_inventory" {
  content  = <<-EOT
[primary_validators]
%{for i, inst in aws_instance.primary_validators~}
primary-validator-${i + 1} ansible_host=${inst.public_ip} private_ip=${inst.private_ip} ansible_user=ubuntu node_type=primary-validator
%{endfor~}

[all_validators:children]
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
  filename = "${path.module}/../../ansible/inventory/aws_primary_hosts"
}
