variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "availability_zones" {
  description = "Availability zones to use"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "name_prefix" {
  description = "Prefix for all resource names"
  type        = string
  default     = "avalanche-l1"
}

variable "environment" {
  description = "Environment name (e.g., fuji, mainnet)"
  type        = string
  default     = "fuji"
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "operator_ip" {
  description = "Operator IP for SSH/API access (CIDR format, e.g., 1.2.3.4/32). Leave empty to auto-detect."
  type        = string
  default     = ""
}

#
# Node Configuration
#

variable "validator_count" {
  description = "Number of validator nodes"
  type        = number
  default     = 3
}

variable "rpc_archive_count" {
  description = "Number of archive RPC nodes (full history, debug APIs)"
  type        = number
  default     = 1
}

variable "rpc_pruned_count" {
  description = "Number of pruned RPC nodes (state-sync, minimal APIs)"
  type        = number
  default     = 1
}

variable "validator_instance_type" {
  description = "EC2 instance type for validators"
  type        = string
  default     = "c6a.xlarge" # 4 vCPU, 8GB RAM - production validators
}

variable "rpc_archive_instance_type" {
  description = "EC2 instance type for archive RPC nodes"
  type        = string
  default     = "c6a.xlarge" # 4 vCPU, 8GB RAM - needs resources for debug APIs
}

variable "rpc_pruned_instance_type" {
  description = "EC2 instance type for pruned RPC nodes"
  type        = string
  default     = "c6a.large" # 2 vCPU, 4GB RAM - lighter workload
}

variable "disk_size_gb" {
  description = "Root disk size in GB for validators"
  type        = number
  default     = 500
}

variable "rpc_archive_disk_size_gb" {
  description = "Disk size for archive RPC nodes (full history requires more space)"
  type        = number
  default     = 1000
}

variable "rpc_pruned_disk_size_gb" {
  description = "Disk size for pruned RPC nodes"
  type        = number
  default     = 500
}

variable "disk_iops" {
  description = "Provisioned IOPS for gp3 volumes (3000 included free)"
  type        = number
  default     = 3000
}

variable "disk_throughput" {
  description = "Provisioned throughput in MB/s for gp3 volumes (125 included free)"
  type        = number
  default     = 125
}

#
# SSH Configuration
#

variable "ssh_public_key" {
  description = "SSH public key content. If provided, creates a new key pair."
  type        = string
  default     = ""
}

variable "ssh_key_name" {
  description = "Existing SSH key pair name. Takes precedence over ssh_public_key."
  type        = string
  default     = ""
}

variable "ssh_private_key_file" {
  description = "Path to SSH private key file for Ansible inventory (e.g., ~/.ssh/my-key)"
  type        = string
  default     = ""
}

#
# Access Configuration
#

variable "enable_public_rpc" {
  description = "Allow public access to RPC nodes"
  type        = bool
  default     = false
}

variable "enable_public_grafana" {
  description = "Allow public access to Grafana dashboard"
  type        = bool
  default     = true
}

variable "enable_public_blockscout" {
  description = "Allow public access to Blockscout block explorer"
  type        = bool
  default     = true
}

variable "enable_public_faucet" {
  description = "Allow public access to the faucet UI/API (port 8010 on RPC nodes)"
  type        = bool
  default     = false
}

variable "enable_public_safe" {
  description = "Allow public access to Safe multisig UI"
  type        = bool
  default     = true
}

#
# Monitoring Configuration
#

variable "monitoring_instance_type" {
  description = "EC2 instance type for monitoring server (Prometheus, Grafana)"
  type        = string
  default     = "t3.small" # 2 vCPU, 2GB RAM - no NVMe needed
}

variable "monitoring_disk_size_gb" {
  description = "Disk size for monitoring server in GB"
  type        = number
  default     = 50
}

variable "enable_staking_key_backup" {
  description = "Enable S3 backup for validator staking keys"
  type        = bool
  default     = true
}

variable "owner_tag" {
  description = "Value for an Owner tag applied to all resources via provider default_tags. Required by some org SCPs; leave empty to skip."
  type        = string
  default     = ""
}
