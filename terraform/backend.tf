terraform {
  required_version = ">= 1.7.0"

  backend "s3" {
    bucket       = "part--aps1-az1--x-s31--aps1-az1--x-s3--aps1-az1--x-s3"   # ← Change this to a real bucket name
    key          = "ecommerce/prod/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }
}