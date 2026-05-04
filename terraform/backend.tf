terraform {
  required_version = ">= 1.7.0"

  backend "s3" {
    bucket       = "parth--aps1-az1--x-s3"
    key          = "terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }
}