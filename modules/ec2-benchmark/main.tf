terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

data "aws_caller_identity" "current" {}

# IAM Role for EC2 to access S3
resource "aws_iam_role" "ec2_s3_role" {
  name = "${var.bucket_name}-ec2-s3-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

# IAM Policy for S3 access (EC2 instance profile)
resource "aws_iam_role_policy" "s3_access" {
  name = "${var.bucket_name}-s3-access-policy"
  role = aws_iam_role.ec2_s3_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:ListBucketVersions",
          "s3:GetBucketLocation"
        ]
        Resource = [
          var.bucket_arn,
          "${var.bucket_arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3files:ClientMount",
          "s3files:ClientWrite",
          "s3files:ClientRootAccess"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ListAllMyBuckets"
        ]
        Resource = "*"
      }
    ]
  })
}

# IAM Instance Profile
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.bucket_name}-ec2-profile"
  role = aws_iam_role.ec2_s3_role.name

  tags = var.tags
}

# AWS managed policy for S3 Files client
resource "aws_iam_role_policy_attachment" "s3_files_client_full" {
  role       = aws_iam_role.ec2_s3_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FilesClientFullAccess"
}

# IAM Role for S3 Files service to access the bucket
# Note: S3 Files is not available in all regions. Set enable_s3_files=true only in supported regions.
resource "aws_iam_role" "s3_files_service_role" {
  count = var.enable_s3_files ? 1 : 0
  name  = "${substr(var.bucket_name, 0, 32)}-s3files-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowS3FilesAssumeRole"
        Effect    = "Allow"
        Principal = { Service = "elasticfilesystem.amazonaws.com" }
        Action    = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
          ArnLike = {
            "aws:SourceArn" = "arn:aws:s3files:${var.region}:${data.aws_caller_identity.current.account_id}:file-system/*"
          }
        }
      }
    ]
  })

  tags = var.tags
}

# IAM Policy for S3 Files to access the bucket (service role policy)
resource "aws_iam_role_policy" "s3_files_service_policy" {
  count = var.enable_s3_files ? 1 : 0
  name  = "${substr(var.bucket_name, 0, 32)}-s3files-policy"
  role  = aws_iam_role.s3_files_service_role[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3BucketPermissions"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:ListBucketVersions"
        ]
        Resource = var.bucket_arn
        Condition = {
          StringEquals = {
            "aws:ResourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        Sid    = "S3ObjectPermissions"
        Effect = "Allow"
        Action = [
          "s3:AbortMultipartUpload",
          "s3:DeleteObject*",
          "s3:GetObject*",
          "s3:List*",
          "s3:PutObject*"
        ]
        Resource = "${var.bucket_arn}/*"
        Condition = {
          StringEquals = {
            "aws:ResourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        Sid    = "EventBridgeManage"
        Effect = "Allow"
        Action = [
          "events:DeleteRule",
          "events:DisableRule",
          "events:EnableRule",
          "events:PutRule",
          "events:PutTargets",
          "events:RemoveTargets"
        ]
        Resource = "arn:aws:events:*:*:rule/DO-NOT-DELETE-S3-Files*"
        Condition = {
          StringEquals = {
            "events:ManagedBy" = "elasticfilesystem.amazonaws.com"
          }
        }
      },
      {
        Sid    = "EventBridgeRead"
        Effect = "Allow"
        Action = [
          "events:DescribeRule",
          "events:ListRuleNamesByTarget",
          "events:ListRules",
          "events:ListTargetsByRule"
        ]
        Resource = "*"
      }
    ]
  })
}

# Security Group
resource "aws_security_group" "benchmark_sg" {
  name        = "${var.bucket_name}-benchmark-sg"
  description = "Security group for S3 benchmark EC2 instance"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_cidr_blocks
  }

  ingress {
    description = "NFS for S3 Files"
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

# S3 Files File System
resource "aws_s3files_file_system" "this" {
  count    = var.enable_s3_files ? 1 : 0
  bucket   = var.bucket_arn
  role_arn = aws_iam_role.s3_files_service_role[0].arn

  tags = var.tags
}

# S3 Files Mount Target
resource "aws_s3files_mount_target" "this" {
  count           = var.enable_s3_files ? 1 : 0
  file_system_id  = aws_s3files_file_system.this[0].id
  subnet_id       = var.subnet_id
  security_groups = [aws_security_group.benchmark_sg.id]

  depends_on = [aws_s3files_file_system.this]
}

# Data source for default AMI if not provided
data "aws_ami" "amazon_linux" {
  count = var.ami_id == "" ? 1 : 0

  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# EC2 Instance — uploads benchmark script to S3, then boots EC2 which
# downloads and executes it.  This avoids the 16 KB user-data limit.

resource "aws_s3_object" "benchmark_script" {
  bucket  = var.bucket_name
  key     = "benchmark/benchmark.sh"
  content = file("${path.module}/../../scripts/benchmark.sh")
  # Use source_hash instead of etag because the bucket uses SSE-KMS,
  # which causes S3 to return a non-MD5 etag.
  source_hash = filemd5("${path.module}/../../scripts/benchmark.sh")
}

resource "aws_instance" "benchmark" {
  ami                    = var.ami_id != "" ? var.ami_id : data.aws_ami.amazon_linux[0].id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  key_name               = var.key_name != "" ? var.key_name : null
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name
  vpc_security_group_ids = [aws_security_group.benchmark_sg.id]

  associate_public_ip_address = var.associate_public_ip

  depends_on = [aws_s3_object.benchmark_script]

  user_data = <<-USERDATA
    #!/bin/bash
    set -euo pipefail
    
    # Install amazon-efs-utils for S3 Files (required by S3 Files client)
    yum install -y amazon-efs-utils
    
    # Botocore is optional for CloudWatch monitoring - skip if not available
    
    BUCKET="${var.bucket_name}"
    FILE_SIZES="${join(" ", var.benchmark_config.file_sizes)}"
    NUM_FILES="${var.benchmark_config.num_files_per_size}"
    ENABLE_FUSE="${var.benchmark_config.enable_s3_fuse}"
    ENABLE_S3_FILES="${var.enable_s3_files}"
    REGION="${var.region}"
    S3_FILES_ROLE_ARN="${var.enable_s3_files ? aws_iam_role.s3_files_service_role[0].arn : ""}"
    S3_FILES_FS_ID="${var.enable_s3_files ? aws_s3files_file_system.this[0].id : ""}"
    aws s3 cp "s3://$BUCKET/benchmark/benchmark.sh" /root/benchmark.sh
    chmod +x /root/benchmark.sh
    BUCKET_NAME="$BUCKET" FILE_SIZES="$FILE_SIZES" NUM_FILES_PER_SIZE="$NUM_FILES" ENABLE_S3_FUSE="$ENABLE_FUSE" ENABLE_S3_FILES="$ENABLE_S3_FILES" REGION="$REGION" S3_FILES_ROLE_ARN="$S3_FILES_ROLE_ARN" S3_FILES_FS_ID="$S3_FILES_FS_ID" bash /root/benchmark.sh
  USERDATA

  root_block_device {
    volume_type = "gp3"
    volume_size = 50
    encrypted   = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tags = merge(var.tags, {
    Name = "${var.bucket_name}-benchmark-instance"
  })
}
