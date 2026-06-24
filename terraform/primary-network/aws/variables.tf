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
  default     = "avalanche-primary"
}

variable "environment" {
  description = "Environment name (e.g., fuji, mainnet)"
  type        = string
  default     = "fuji"
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.1.0.0/16"
}

variable "operator_ip" {
  description = "Operator IP for SSH/API access (CIDR format, e.g., 1.2.3.4/32). Leave empty to auto-detect."
  type        = string
  default     = ""
}

#
# Primary Validator Configuration
#

variable "primary_validator_count" {
  description = "Number of Primary Network validators"
  type        = number
  default     = 1
}

variable "primary_validator_instance_type" {
  description = "EC2 instance type for Primary Network validators (must have NVMe)"
  type        = string
  default     = "i7i.xlarge" # 4 vCPU, 32GB RAM, 937GB NVMe
}

variable "primary_validator_root_disk_gb" {
  description = "Root EBS disk size for Primary Network validators (OS only)"
  type        = number
  default     = 50 # OS + binaries only, data on NVMe
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

variable "enable_public_grafana" {
  description = "Allow public access to Grafana dashboard"
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

#
# Staking Key Backup
#

variable "enable_staking_key_backup" {
  description = "Enable S3 backup for validator staking keys"
  type        = bool
  default     = true
}
