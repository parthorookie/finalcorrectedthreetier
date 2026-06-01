variable "project_name" {
  description = "Project name"
  type        = string
  default     = "ecommerce"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "prod"
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for EKS and Fargate"
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "List of public subnet IDs (for ALB)"
  type        = list(string)
}

variable "operator_ip_cidr" {
  description = "Operator IP CIDR for security group access"
  type        = string
}

variable "region" {
  description = "AWS Region"
  type        = string
}