module "vpc" {
  source               = "./modules/vpc"
  project_name         = var.project_name
  environment          = var.environment
  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  availability_zones   = var.availability_zones
}


module "eks" {
  source                  = "./modules/eks"
  project_name            = var.project_name
  environment             = var.environment
  vpc_id                  = module.vpc.vpc_id
  private_subnet_ids      = module.vpc.private_subnet_ids
  node_instance_types     = var.eks_node_instance_types
  desired_size            = var.eks_desired_size
  min_size                = var.eks_min_size
  max_size                = var.eks_max_size
}

module "aurora" {
  source             = "./modules/aurora"
  project_name       = var.project_name
  environment        = var.environment
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  db_password        = var.db_password
  eks_sg_id          = module.eks.node_security_group_id
}

module "rabbitmq_ec2" {
  source             = "./modules/rabbitmq-ec2"
  project_name       = var.project_name
  environment        = var.environment
  vpc_id             = module.vpc.vpc_id
  public_subnet_id = module.vpc.public_subnet_ids[0]
  operator_ip_cidr = var.operator_ip_cidr
  instance_type      = var.rabbitmq_instance_type
  ami_id             = var.rabbitmq_ami
  eks_sg_id          = module.eks.node_security_group_id
}

module "alb_waf" {
  source            = "./modules/alb-waf"
  project_name      = var.project_name
  environment       = var.environment
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnet_ids
  eks_sg_id         = module.eks.node_security_group_id
}


