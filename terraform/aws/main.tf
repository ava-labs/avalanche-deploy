terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# Get operator IP automatically
data "http" "operator_ip" {
  url = "https://checkip.amazonaws.com"
}

locals {
  operator_cidr = var.operator_ip != "" ? var.operator_ip : "${chomp(data.http.operator_ip.response_body)}/32"
  common_tags = {
    Project     = "avalanche-l1"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

#
# NETWORKING
#

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-vpc"
  })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-igw"
  })
}

resource "aws_subnet" "public" {
  count                   = length(var.availability_zones)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-public-${count.index + 1}"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-public-rt"
  })
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

#
# SECURITY GROUPS
#

resource "aws_security_group" "validators" {
  name        = "${var.name_prefix}-validators"
  description = "Security group for Avalanche L1 validators"
  vpc_id      = aws_vpc.main.id

  # SSH - operator only
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.operator_cidr]
  }

  # Avalanche HTTP API - operator only
  ingress {
    description = "Avalanche HTTP API"
    from_port   = 9650
    to_port     = 9650
    protocol    = "tcp"
    cidr_blocks = [local.operator_cidr]
  }

  # Avalanche staking port - public (required for P2P)
  ingress {
    description = "Avalanche Staking P2P"
    from_port   = 9651
    to_port     = 9651
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Inter-validator communication
  ingress {
    description = "Inter-validator"
    from_port   = 9650
    to_port     = 9651
    protocol    = "tcp"
    self        = true
  }

  # Avalanche metrics scraping from within VPC
  ingress {
    description = "Avalanche metrics from VPC"
    from_port   = 9650
    to_port     = 9650
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # Node exporter metrics from within VPC
  ingress {
    description = "Node exporter metrics from VPC"
    from_port   = 9100
    to_port     = 9100
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-validators-sg"
  })
}

resource "aws_security_group" "rpc" {
  name        = "${var.name_prefix}-rpc"
  description = "Security group for Avalanche L1 RPC nodes"
  vpc_id      = aws_vpc.main.id

  # SSH - operator only
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.operator_cidr]
  }

  # RPC API - configurable (operator or public)
  ingress {
    description = "Avalanche RPC API"
    from_port   = 9650
    to_port     = 9650
    protocol    = "tcp"
    cidr_blocks = var.enable_public_rpc ? ["0.0.0.0/0"] : [local.operator_cidr]
  }

  # Staking port - public (required for P2P sync)
  ingress {
    description = "Avalanche P2P"
    from_port   = 9651
    to_port     = 9651
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Blockscout API - configurable (runs on RPC node)
  ingress {
    description = "Blockscout API"
    from_port   = 4000
    to_port     = 4000
    protocol    = "tcp"
    cidr_blocks = var.enable_public_blockscout ? ["0.0.0.0/0"] : [local.operator_cidr]
  }

  # Blockscout Frontend - configurable (runs on RPC node)
  ingress {
    description = "Blockscout Frontend"
    from_port   = 4001
    to_port     = 4001
    protocol    = "tcp"
    cidr_blocks = var.enable_public_blockscout ? ["0.0.0.0/0"] : [local.operator_cidr]
  }

  # Blockscout Stats API - configurable (runs on RPC node, needed for frontend charts)
  ingress {
    description = "Blockscout Stats"
    from_port   = 8050
    to_port     = 8050
    protocol    = "tcp"
    cidr_blocks = var.enable_public_blockscout ? ["0.0.0.0/0"] : [local.operator_cidr]
  }

  # Safe Multisig UI - configurable (runs on RPC node)
  ingress {
    description = "Safe UI"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = var.enable_public_safe ? ["0.0.0.0/0"] : [local.operator_cidr]
  }

  # Safe Client Gateway - configurable (runs on RPC node, needed by UI)
  ingress {
    description = "Safe Client Gateway"
    from_port   = 8003
    to_port     = 8003
    protocol    = "tcp"
    cidr_blocks = var.enable_public_safe ? ["0.0.0.0/0"] : [local.operator_cidr]
  }

  # Safe HTTPS - required for wallet connection (Web Crypto API needs secure context)
  ingress {
    description = "Safe HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.enable_public_safe ? ["0.0.0.0/0"] : [local.operator_cidr]
  }

  # Avalanche metrics scraping from within VPC
  ingress {
    description = "Avalanche metrics from VPC"
    from_port   = 9650
    to_port     = 9650
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # Node exporter metrics from within VPC
  ingress {
    description = "Node exporter metrics from VPC"
    from_port   = 9100
    to_port     = 9100
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-rpc-sg"
  })
}

resource "aws_security_group" "monitoring" {
  name        = "${var.name_prefix}-monitoring"
  description = "Security group for dedicated monitoring server (Prometheus, Grafana)"
  vpc_id      = aws_vpc.main.id

  # SSH - operator only
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.operator_cidr]
  }

  # Grafana - configurable
  ingress {
    description = "Grafana"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = var.enable_public_grafana ? ["0.0.0.0/0"] : [local.operator_cidr]
  }

  # Prometheus - operator only
  ingress {
    description = "Prometheus"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = [local.operator_cidr]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-monitoring-sg"
  })
}

#
# SSH KEY
#

resource "aws_key_pair" "main" {
  count      = var.ssh_public_key != "" ? 1 : 0
  key_name   = "${var.name_prefix}-key"
  public_key = var.ssh_public_key

  tags = local.common_tags
}

#
# EC2 INSTANCES - VALIDATORS
#

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "validators" {
  count = var.validator_count

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.validator_instance_type
  key_name               = var.ssh_key_name != "" ? var.ssh_key_name : (length(aws_key_pair.main) > 0 ? aws_key_pair.main[0].key_name : null)
  subnet_id              = aws_subnet.public[count.index % length(aws_subnet.public)].id
  vpc_security_group_ids = [aws_security_group.validators.id]
  iam_instance_profile   = local.enable_key_backup ? aws_iam_instance_profile.validator[0].name : null

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = var.disk_size_gb
    volume_type = "gp3"
    iops        = var.disk_iops
    throughput  = var.disk_throughput
    encrypted   = true
  }

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-validator-${count.index + 1}"
    Role = "validator"
  })
}

#
# EC2 INSTANCES - ARCHIVE RPC NODES (full history, debug APIs)
#

resource "aws_instance" "rpc_archive" {
  count = var.rpc_archive_count

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.rpc_archive_instance_type
  key_name               = var.ssh_key_name != "" ? var.ssh_key_name : (length(aws_key_pair.main) > 0 ? aws_key_pair.main[0].key_name : null)
  subnet_id              = aws_subnet.public[count.index % length(aws_subnet.public)].id
  vpc_security_group_ids = [aws_security_group.rpc.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = var.rpc_archive_disk_size_gb
    volume_type = "gp3"
    iops        = var.disk_iops
    throughput  = var.disk_throughput
    encrypted   = true
  }

  tags = merge(local.common_tags, {
    Name    = "${var.name_prefix}-rpc-archive-${count.index + 1}"
    Role    = "rpc"
    RpcType = "archive"
  })
}

#
# EC2 INSTANCES - PRUNED RPC NODES (state-sync, minimal APIs)
#

resource "aws_instance" "rpc_pruned" {
  count = var.rpc_pruned_count

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.rpc_pruned_instance_type
  key_name               = var.ssh_key_name != "" ? var.ssh_key_name : (length(aws_key_pair.main) > 0 ? aws_key_pair.main[0].key_name : null)
  subnet_id              = aws_subnet.public[count.index % length(aws_subnet.public)].id
  vpc_security_group_ids = [aws_security_group.rpc.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = var.rpc_pruned_disk_size_gb
    volume_type = "gp3"
    iops        = var.disk_iops
    throughput  = var.disk_throughput
    encrypted   = true
  }

  tags = merge(local.common_tags, {
    Name    = "${var.name_prefix}-rpc-pruned-${count.index + 1}"
    Role    = "rpc"
    RpcType = "pruned"
  })
}

#
# EC2 INSTANCE - MONITORING
#

resource "aws_instance" "monitoring" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.monitoring_instance_type
  key_name               = var.ssh_key_name != "" ? var.ssh_key_name : (length(aws_key_pair.main) > 0 ? aws_key_pair.main[0].key_name : null)
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.monitoring.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = var.monitoring_disk_size_gb
    volume_type = "gp3"
    encrypted   = true
  }

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-monitoring"
    Role = "monitoring"
  })
}

#
# S3 BUCKET FOR STAKING KEY BACKUPS
#

# Local to determine if we need staking key backup infrastructure
locals {
  enable_key_backup = var.enable_staking_key_backup && (var.validator_count > 0 || var.primary_validator_count > 0)
}

resource "aws_s3_bucket" "staking_keys" {
  count         = local.enable_key_backup ? 1 : 0
  bucket        = "${var.name_prefix}-validator-keys"
  force_destroy = true

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-validator-keys"
  })
}

resource "aws_s3_bucket_versioning" "staking_keys" {
  count  = local.enable_key_backup ? 1 : 0
  bucket = aws_s3_bucket.staking_keys[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "staking_keys" {
  count  = local.enable_key_backup ? 1 : 0
  bucket = aws_s3_bucket.staking_keys[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.staking_keys[0].arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "staking_keys" {
  count  = local.enable_key_backup ? 1 : 0
  bucket = aws_s3_bucket.staking_keys[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_kms_key" "staking_keys" {
  count                   = local.enable_key_backup ? 1 : 0
  description             = "KMS key for staking key encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-staking-keys-kms"
  })
}

resource "aws_kms_alias" "staking_keys" {
  count         = local.enable_key_backup ? 1 : 0
  name          = "alias/${var.name_prefix}-staking-keys"
  target_key_id = aws_kms_key.staking_keys[0].key_id
}

#
# IAM ROLE FOR VALIDATORS (S3 ACCESS)
#

resource "aws_iam_role" "validator" {
  count = local.enable_key_backup ? 1 : 0
  name  = "${var.name_prefix}-validator-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "validator_s3" {
  count = local.enable_key_backup ? 1 : 0
  name  = "staking-keys-access"
  role  = aws_iam_role.validator[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.staking_keys[0].arn,
          "${aws_s3_bucket.staking_keys[0].arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = aws_kms_key.staking_keys[0].arn
      }
    ]
  })
}

resource "aws_iam_instance_profile" "validator" {
  count = local.enable_key_backup ? 1 : 0
  name  = "${var.name_prefix}-validator-profile"
  role  = aws_iam_role.validator[0].name
}

#
# SECURITY GROUP - PRIMARY NETWORK VALIDATORS
#

resource "aws_security_group" "primary_validators" {
  count       = var.primary_validator_count > 0 ? 1 : 0
  name        = "${var.name_prefix}-primary-validators"
  description = "Security group for Avalanche Primary Network validators"
  vpc_id      = aws_vpc.main.id

  # SSH - operator only
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.operator_cidr]
  }

  # Avalanche HTTP API - operator only (no public RPC)
  ingress {
    description = "Avalanche HTTP API"
    from_port   = 9650
    to_port     = 9650
    protocol    = "tcp"
    cidr_blocks = [local.operator_cidr]
  }

  # Avalanche staking port - public (required for P2P)
  ingress {
    description = "Avalanche Staking P2P"
    from_port   = 9651
    to_port     = 9651
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Avalanche metrics scraping from within VPC
  ingress {
    description = "Avalanche metrics from VPC"
    from_port   = 9650
    to_port     = 9650
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # Node exporter metrics from within VPC
  ingress {
    description = "Node exporter metrics from VPC"
    from_port   = 9100
    to_port     = 9100
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-primary-validators-sg"
  })
}

#
# EC2 INSTANCES - PRIMARY NETWORK VALIDATORS
#

resource "aws_instance" "primary_validators" {
  count = var.primary_validator_count

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.primary_validator_instance_type
  key_name               = var.ssh_key_name != "" ? var.ssh_key_name : (length(aws_key_pair.main) > 0 ? aws_key_pair.main[0].key_name : null)
  subnet_id              = aws_subnet.public[count.index % length(aws_subnet.public)].id
  vpc_security_group_ids = [aws_security_group.primary_validators[0].id]
  iam_instance_profile   = local.enable_key_backup ? aws_iam_instance_profile.validator[0].name : null

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  # Small root EBS for OS only (data goes on NVMe)
  root_block_device {
    volume_size = var.primary_validator_root_disk_gb
    volume_type = "gp3"
    encrypted   = true
  }

  # NVMe is ephemeral and attached automatically with i4i instances

  tags = merge(local.common_tags, {
    Name     = "${var.name_prefix}-primary-validator-${count.index + 1}"
    Role     = "primary-validator"
    NodeType = "primary-network"
  })
}
