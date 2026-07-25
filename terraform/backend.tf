terraform {
  required_version = ">= 1.7.0"

  backend "s3" {
    bucket       = "ecommerce-terraform-state-ap-south-1"   # ← Change this to a real bucket name
    key          = "ecommerce/prod/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }
}