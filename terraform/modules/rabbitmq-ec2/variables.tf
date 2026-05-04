variable "project_name"  { type = string }
variable "environment"   { type = string }
variable "vpc_id"        { type = string }
variable "instance_type" { type = string }
variable "ami_id"        { type = string }
variable "eks_sg_id"     { type = string }

# FIX: renamed from private_subnet_id → public_subnet_id
# EC2 must be in a public subnet to receive a routable public IPv4
variable "public_subnet_id" {
  type        = string
  description = "Public subnet ID — EC2 placed here to get a public IPv4"
}

variable "rabbitmq_password" {
  type      = string
  sensitive = true
  default   = "changeme123!"
}

# Your public IP in CIDR notation — get it by running: curl ifconfig.me
# Then set the value as: "YOUR.IP.HERE/32"
# NEVER set to 0.0.0.0/0 — that exposes the management UI to the entire internet
variable "operator_ip_cidr" {
  type        = string
  description = "Operator public IP in CIDR format e.g. 203.0.113.45/32 — port 15672 opened to this IP only"
}
