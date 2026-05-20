variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.medium"
}

variable "ami_id" {
  description = "AMI ID for the EC2 instance (default: Amazon Linux 2023)"
  type        = string
  default     = ""
}

variable "subnet_id" {
  description = "Subnet ID where the EC2 instance will be launched"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for security group"
  type        = string
}

variable "key_name" {
  description = "EC2 key pair name for SSH access"
  type        = string
  default     = ""
}

variable "bucket_name" {
  description = "Name of the S3 bucket to benchmark"
  type        = string
}

variable "bucket_arn" {
  description = "ARN of the S3 bucket"
  type        = string
}

variable "benchmark_config" {
  description = "Configuration for the benchmark"
  type = object({
    file_sizes         = list(string) # e.g., ["1KB", "100KB", "1MB", "10MB", "100MB"]
    num_files_per_size = number       # e.g., 10
    enable_s3_fuse     = bool         # Run S3 FUSE tests
  })
  default = {
    file_sizes         = ["1KB", "100KB", "1MB", "10MB", "100MB"]
    num_files_per_size = 5
    enable_s3_fuse     = true
  }
}

variable "associate_public_ip" {
  description = "Associate a public IP address with the instance"
  type        = bool
  default     = true
}

variable "ssh_cidr_blocks" {
  description = "CIDR blocks allowed for SSH access"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "tags" {
  description = "Tags to apply to the EC2 instance"
  type        = map(string)
  default     = {}
}

variable "enable_s3_files" {
  description = "Enable AWS S3 Files benchmarks"
  type        = bool
  default     = true
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "account_id" {
  description = "AWS account ID"
  type        = string
  default     = ""
}
