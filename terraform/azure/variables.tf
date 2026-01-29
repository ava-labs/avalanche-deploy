variable "location" {
  description = "Azure region"
  type        = string
  default     = "East US"
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

variable "vnet_cidr" {
  description = "CIDR block for VNet"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR block for subnet"
  type        = string
  default     = "10.0.1.0/24"
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

variable "validator_vm_size" {
  description = "Azure VM size for validators (Lsv3 series has local NVMe)"
  type        = string
  default     = "Standard_L8s_v3" # 8 vCPU, 64GB RAM, 1x800GB NVMe
}

variable "rpc_vm_size" {
  description = "Azure VM size for RPC nodes (Lsv3 series has local NVMe)"
  type        = string
  default     = "Standard_L8s_v3" # 8 vCPU, 64GB RAM, 1x800GB NVMe
}

variable "disk_size_gb" {
  description = "OS disk size in GB"
  type        = number
  default     = 500
}

#
# SSH Configuration
#

variable "admin_username" {
  description = "Admin username for VMs"
  type        = string
  default     = "azureuser"
}

variable "ssh_public_key" {
  description = "SSH public key content"
  type        = string
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
