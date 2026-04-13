# CI E2E Test: Primary Network Deployment
#
# Primary Network validators require NVMe storage for the full
# chain database (~600GB+ on Fuji with state-sync). i4i.xlarge
# provides 937GB NVMe which is the minimum viable instance type.
#
# 2 validators are needed for migration testing.
#
# Estimated cost: ~$0.96/hr (~$1.92 per 120-minute test run)

name_prefix = "ci-primary"
environment = "fuji"

# 2 validators: source + migration target
primary_validator_count         = 2
primary_validator_instance_type = "i4i.xlarge" # 4 vCPU, 32GB, 937GB NVMe ($0.468/hr)
primary_validator_root_disk_gb  = 50           # OS only, data on NVMe

# Monitoring
monitoring_instance_type = "t3.small" # 2 vCPU, 2GB ($0.021/hr)
monitoring_disk_size_gb  = 30

# Enable backup + migration testing
enable_staking_key_backup = true
enable_public_grafana     = true
