output "eks_cluster_name" {
  description = "Name of the EKS cluster"
  value       = aws_eks_cluster.main.name
}

output "eks_cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = aws_eks_cluster.main.endpoint
}

output "eks_cluster_certificate_authority" {
  description = "Certificate authority for EKS"
  value       = aws_eks_cluster.main.certificate_authority[0].data
}

output "fargate_pod_execution_role_arn" {
  description = "IAM Role ARN used by Fargate pods"
  value       = aws_iam_role.fargate_pod_execution.arn
}

output "cluster_security_group_id" {
  description = "Security group ID attached to EKS cluster"
  value       = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}