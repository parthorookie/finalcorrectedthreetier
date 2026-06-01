resource "aws_iam_role" "fargate_pod_execution" {
  name = "${var.project_name}-fargate-pod-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "eks-fargate-pods.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    Name        = "${var.project_name}-fargate-role"
    Environment = var.environment
  }
}

resource "aws_iam_role_policy_attachment" "fargate_pod_execution" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSFargatePodExecutionRolePolicy"
  role       = aws_iam_role.fargate_pod_execution.name
}

# =============================================================================
# Fargate Profiles
# =============================================================================
resource "aws_eks_fargate_profile" "default" {
  cluster_name           = aws_eks_cluster.main.name
  fargate_profile_name   = "ecommerce-default"
  pod_execution_role_arn = aws_iam_role.fargate_pod_execution.arn
  subnet_ids             = var.private_subnet_ids

  selector {
    namespace = "default"
  }

  selector {
    namespace = "worker"
  }

  tags = {
    Name        = "${var.project_name}-fargate-default"
    Environment = var.environment
  }
}

resource "aws_eks_fargate_profile" "system" {
  cluster_name           = aws_eks_cluster.main.name
  fargate_profile_name   = "ecommerce-system"
  pod_execution_role_arn = aws_iam_role.fargate_pod_execution.arn
  subnet_ids             = var.private_subnet_ids

  selector {
    namespace = "argocd"
  }

  selector {
    namespace = "argo"
  }

  selector {
    namespace = "keda"
  }

  selector {
    namespace = "monitoring"
  }

  selector {
    namespace = "kube-system"
  }

  tags = {
    Name        = "${var.project_name}-fargate-system"
    Environment = var.environment
  }
}