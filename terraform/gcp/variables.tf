variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "zones" {
  description = "GCP zones to use"
  type        = list(string)
  default     = ["us-central1-a", "us-central1-b", "us-central1-c"]
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

variable "subnet_cidr" {
  description = "CIDR block for subnet"
  type        = string
  default     = "10.0.0.0/24"
}

variable "operator_ip" {
  description = "Operator IP for SSH/API access (CIDR format). Leave empty to auto-detect."
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

variable "validator_machine_type" {
  description = "GCP machine type for validators"
  type        = string
  default     = "n2-standard-4" # 4 vCPU, 16GB RAM
}

variable "rpc_machine_type" {
  description = "GCP machine type for RPC nodes"
  type        = string
  default     = "n2-standard-2" # 2 vCPU, 8GB RAM
}

variable "disk_size_gb" {
  description = "Boot disk size in GB (data goes on local SSD)"
  type        = number
  default     = 100
}

variable "local_ssd_count" {
  description = "Number of 375GB local NVMe SSDs to attach (0 = none)"
  type        = number
  default     = 1
}

#
# SSH Configuration
#

variable "ssh_user" {
  description = "SSH username"
  type        = string
  default     = "ubuntu"
}

variable "ssh_public_key" {
  description = "SSH public key content"
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

#
# Monitoring Configuration
#

variable "monitoring_machine_type" {
  description = "GCP machine type for monitoring server (Prometheus, Grafana)"
  type        = string
  default     = "e2-small" # 2 vCPU, 2GB RAM
}

variable "monitoring_disk_size_gb" {
  description = "Disk size for monitoring server in GB"
  type        = number
  default     = 50
}
