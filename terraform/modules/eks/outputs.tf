output "cluster_name" {
  value = aws_eks_cluster.eks.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.eks.endpoint
}

output "cluster_certificate_authority" {
  value = aws_eks_cluster.eks.certificate_authority[0].data
}

output "fargate_profile_name" {
  value = aws_eks_fargate_profile.default.fargate_profile_name
}
