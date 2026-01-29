# Compute Module - Creates VM instances for validators and RPC nodes
# This module is cloud-agnostic and called by provider-specific modules

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

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
  description = "Instance type for validators"
  type        = string
}

variable "rpc_instance_type" {
  description = "Instance type for RPC nodes"
  type        = string
}

variable "disk_size_gb" {
  description = "Root disk size in GB"
  type        = number
  default     = 200
}

variable "ssh_public_key" {
  description = "SSH public key for access"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

# Outputs are defined per-cloud in the provider modules
