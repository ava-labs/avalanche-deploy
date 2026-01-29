# Networking Module - Security groups/firewall rules for Avalanche nodes

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "operator_ip" {
  description = "Operator IP for SSH and API access (CIDR format)"
  type        = string
}

variable "enable_public_rpc" {
  description = "Allow public access to RPC nodes"
  type        = bool
  default     = false
}

variable "enable_public_grafana" {
  description = "Allow public access to Grafana"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

# Port definitions
locals {
  # Avalanche ports
  avalanche_http_port    = 9650
  avalanche_staking_port = 9651

  # Monitoring ports
  prometheus_port = 9090
  grafana_port    = 3000

  # Metrics port (avalanchego exposes metrics on HTTP port)
  metrics_path = "/ext/metrics"
}
