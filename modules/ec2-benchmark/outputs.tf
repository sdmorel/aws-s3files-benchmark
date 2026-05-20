output "instance_id" {
  description = "ID of the EC2 instance"
  value       = aws_instance.benchmark.id
}

output "instance_public_ip" {
  description = "Public IP of the EC2 instance"
  value       = aws_instance.benchmark.public_ip
}

output "instance_private_ip" {
  description = "Private IP of the EC2 instance"
  value       = aws_instance.benchmark.private_ip
}

output "iam_role_name" {
  description = "Name of the IAM role attached to the instance"
  value       = aws_iam_role.ec2_s3_role.name
}

output "security_group_id" {
  description = "ID of the security group"
  value       = aws_security_group.benchmark_sg.id
}

output "s3_files_role_arn" {
  description = "ARN of the IAM role for S3 Files"
  value       = var.enable_s3_files ? aws_iam_role.s3_files_service_role[0].arn : ""
}

output "s3_files_role_name" {
  description = "Name of the IAM role for S3 Files"
  value       = var.enable_s3_files ? aws_iam_role.s3_files_service_role[0].name : ""
}

output "s3_files_file_system_id" {
  description = "ID of the S3 Files file system"
  value       = var.enable_s3_files ? aws_s3files_file_system.this[0].id : ""
}

output "s3_files_mount_target_id" {
  description = "ID of the S3 Files mount target"
  value       = var.enable_s3_files ? aws_s3files_mount_target.this[0].id : ""
}

output "s3_files_mount_target_vpc_id" {
  description = "VPC ID of the S3 Files mount target"
  value       = var.enable_s3_files ? aws_s3files_mount_target.this[0].vpc_id : ""
}
