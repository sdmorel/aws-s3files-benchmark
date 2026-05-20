variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "benchmark"
}

variable "bucket_name" {
  description = "Name of the S3 bucket (must be globally unique)"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the EC2 instance will be launched"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID where the EC2 instance will be launched"
  type        = string
}

variable "key_name" {
  description = "EC2 key pair name for SSH access"
  type        = string
  default     = ""
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.medium"
}

variable "file_sizes" {
  description = "List of file sizes to test"
  type        = list(string)
  default     = ["1KB", "100KB", "1MB", "10MB", "100MB"]
}

variable "num_files_per_size" {
  description = "Number of files to test per size"
  type        = number
  default     = 10
}

variable "enable_s3_fuse" {
  description = "Enable S3 FUSE benchmarks"
  type        = bool
  default     = true
}

variable "enable_s3_files" {
  description = "Enable AWS S3 Files benchmarks"
  type        = bool
  default     = true
}

variable "ssh_cidr_blocks" {
  description = "CIDR blocks allowed for SSH access"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
