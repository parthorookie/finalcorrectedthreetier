output "cluster_name" {
  value = aws_eks_cluster.eks.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.eks.endpoint
}

output "node_security_group_id" {
  value = aws_security_group.eks_nodes.id
}

output "cluster_certificate_authority" {
  value = aws_eks_cluster.eks.certificate_authority[0].data
}
