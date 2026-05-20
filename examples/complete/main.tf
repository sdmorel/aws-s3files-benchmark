terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "aws-s3-benchmark"
      ManagedBy   = "OpenTofu"
      Environment = var.environment
    }
  }
}

module "s3_bucket" {
  source = "../../modules/s3-bucket"

  bucket_name         = var.bucket_name
  region              = var.region
  versioning_enabled  = true
  block_public_access = true

  tags = {
    Environment = var.environment
    Purpose     = "benchmark"
  }
}

module "ec2_benchmark" {
  source = "../../modules/ec2-benchmark"

  bucket_name = module.s3_bucket.bucket_name
  bucket_arn  = module.s3_bucket.bucket_arn

  vpc_id        = var.vpc_id
  subnet_id     = var.subnet_id
  instance_type = var.instance_type
  key_name      = var.key_name

  benchmark_config = {
    file_sizes         = var.file_sizes
    num_files_per_size = var.num_files_per_size
    enable_s3_fuse     = var.enable_s3_fuse
  }

  enable_s3_files = var.enable_s3_files
  region          = var.region

  ssh_cidr_blocks = var.ssh_cidr_blocks

  tags = {
    Environment = var.environment
    Purpose     = "benchmark"
  }
}
