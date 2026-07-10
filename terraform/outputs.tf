output "eks_cluster_name" {
  value = module.eks.eks_cluster_name     # Fixed
}

output "aurora_endpoint" {
  value = module.aurora.cluster_endpoint
}

output "alb_dns_name" {
  value = module.alb_waf.alb_dns_name
}

output "vpc_id" {
  value = module.vpc.vpc_id
}