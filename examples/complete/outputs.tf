output "bucket_name" {
  description = "Name of the created S3 bucket"
  value       = module.s3_bucket.bucket_name
}

output "bucket_arn" {
  description = "ARN of the created S3 bucket"
  value       = module.s3_bucket.bucket_arn
}

output "instance_id" {
  description = "ID of the benchmark EC2 instance"
  value       = module.ec2_benchmark.instance_id
}

output "instance_public_ip" {
  description = "Public IP of the EC2 instance"
  value       = module.ec2_benchmark.instance_public_ip
}

output "instance_private_ip" {
  description = "Private IP of the EC2 instance"
  value       = module.ec2_benchmark.instance_private_ip
}

output "ssh_command" {
  description = "SSH command to connect to the instance"
  value       = "ssh -i your-key.pem ec2-user@${module.ec2_benchmark.instance_public_ip}"
}

output "results_location" {
  description = "Location of benchmark results on the EC2 instance"
  value       = "/root/benchmark-results/"
}

output "download_results_command" {
  description = "Command to download benchmark results"
  value       = "scp -i your-key.pem root@${module.ec2_benchmark.instance_public_ip}:/root/benchmark-results/* ./"
}

output "s3_files_role_arn" {
  description = "ARN of the IAM role for S3 Files"
  value       = module.ec2_benchmark.s3_files_role_arn
}

output "s3_files_role_name" {
  description = "Name of the IAM role for S3 Files"
  value       = module.ec2_benchmark.s3_files_role_name
}

output "s3_files_file_system_id" {
  description = "ID of the S3 Files file system"
  value       = module.ec2_benchmark.s3_files_file_system_id
}
