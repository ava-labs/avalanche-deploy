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

variable "rpc_count" {
  description = "Number of RPC nodes"
  type        = number
  default     = 2
}

variable "validator_instance_type" {
  description = "EC2 instance type for validators"
  type        = string
  default     = "m6i.2xlarge" # 8 vCPU, 32GB RAM
}

variable "rpc_instance_type" {
  description = "EC2 instance type for RPC nodes"
  type        = string
  default     = "m6i.xlarge" # 4 vCPU, 16GB RAM
}

variable "disk_size_gb" {
  description = "Root disk size in GB"
  type        = number
  default     = 500
}

variable "disk_iops" {
  description = "Provisioned IOPS for gp3 volumes"
  type        = number
  default     = 6000
}

variable "disk_throughput" {
  description = "Provisioned throughput in MB/s for gp3 volumes"
  type        = number
  default     = 500
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
