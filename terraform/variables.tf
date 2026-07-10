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
  description = "Availability Zones"
  type        = list(string)
  default     = ["ap-south-1a", "ap-south-1b"]
}

################################
# FARGATE
################################

variable "fargate_namespaces" {
  description = "Namespaces scheduled onto Fargate"
  type        = list(string)

  default = [
    "default",
    "kube-system"
  ]
}

variable "operator_ip_cidr" {
  description = "CIDR block for operator/admin access (your public IP)"
  type        = string
  default     = "0.0.0.0/0"   # Change this in production!
}