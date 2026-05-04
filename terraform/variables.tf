################################
# GLOBAL
################################
variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Project name prefix"
  type        = string
  default     = "ecommerce"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "prod"
}

################################
# DATABASE
################################
variable "db_password" {
  description = "Aurora PostgreSQL master password"
  type        = string
  sensitive   = true
}

################################
# NETWORKING (VPC)
################################
variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDRs"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDRs"
  type        = list(string)
  default     = ["10.0.3.0/24", "10.0.4.0/24"]
}

variable "availability_zones" {
  description = "Availability zones"
  type        = list(string)
  default     = ["ap-south-1a", "ap-south-1b"]
}

################################
# EKS CONFIG
################################
variable "eks_node_instance_types" {
  description = "EKS node instance types"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "eks_desired_size" {
  description = "Desired node count"
  type        = number
  default     = 2
}

variable "eks_min_size" {
  description = "Minimum node count"
  type        = number
  default     = 1
}

variable "eks_max_size" {
  description = "Maximum node count"
  type        = number
  default     = 5
}

################################
# RABBITMQ (EC2)
################################
variable "rabbitmq_instance_type" {
  description = "Instance type for RabbitMQ EC2"
  type        = string
  default     = "t3.medium"
}

variable "rabbitmq_ami" {
  description = "Amazon Linux 2023 AMI for ap-south-1"
  type        = string
  default     = "ami-0f58b397bc5c1f2e8"
}

variable "rabbitmq_password" {
  description = "RabbitMQ admin password"
  type        = string
  sensitive   = true
}

variable "operator_ip_cidr" {
  description = "Your public IP for RabbitMQ UI access (e.g. x.x.x.x/32)"
  type        = string
}

