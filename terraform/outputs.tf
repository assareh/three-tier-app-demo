output "backups_s3_bucket_url" {
  description = "URL of Backups S3 bucket"
  value       = "https://${aws_s3_bucket.backups.id}.s3.${aws_s3_bucket.backups.region}.amazonaws.com"
}

output "caller" {
  value = data.aws_caller_identity.current.arn
}

output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = module.eks.cluster_endpoint
}

output "cluster_name" {
  description = "Kubernetes Cluster Name"
  value       = module.eks.cluster_name
}

output "configure_kubectl" {
  description = "Command to run to configure kubectl with access to your cluster"
  value       = "aws eks --region ${var.region} update-kubeconfig --name ${module.eks.cluster_name}"
}

output "db_instance_private_ip" {
  description = "Private IP of DB Instance"
  value       = aws_instance.db.private_ip
}

output "db_ssh_command" {
  description = "Command to access the db host"
  value       = "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${local.private_key_filename} ubuntu@${aws_instance.db.public_dns}"
}

output "mongodb_password" {
  description = "MongoDB root password"
  value       = var.mongodb_password
}

output "mongodb_username" {
  description = "MongoDB root username"
  value       = var.mongodb_username
}

output "region" {
  description = "AWS region"
  value       = var.region
}
