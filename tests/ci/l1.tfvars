# CI E2E Test: L1 Deployment
#
# Cost-optimized instance types for automated testing.
# These are smaller than production defaults but sufficient
# for exercising the full deployment + add-on lifecycle.
#
# Estimated cost: ~$0.31/hr (~$0.47 per 90-minute test run)

name_prefix = "ci-l1"
environment = "fuji"

# 3 validators needed for quorum + rolling restart testing
validator_count   = 3
rpc_archive_count = 1 # hosts Blockscout, Safe, Graph Node, Faucet
rpc_pruned_count  = 0 # not needed for E2E validation

# Smaller instance types — sufficient for a fresh L1 with no traffic
validator_instance_type   = "t3.medium" # 2 vCPU, 4GB  ($0.042/hr)
rpc_archive_instance_type = "t3.xlarge" # 4 vCPU, 16GB ($0.166/hr) — needs RAM for Docker add-ons
monitoring_instance_type  = "t3.small"  # 2 vCPU, 2GB  ($0.021/hr)

# Smaller disks — L1 starts from genesis with zero history
disk_size_gb             = 100 # validators
rpc_archive_disk_size_gb = 150 # archive RPC
monitoring_disk_size_gb  = 30

# Keep free-tier IOPS/throughput
disk_iops       = 3000
disk_throughput = 125

# Enable backup testing
enable_staking_key_backup = true

# Allow access to all services for health checks
enable_public_rpc        = true
enable_public_grafana    = true
enable_public_blockscout = true
enable_public_safe       = true
