terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "eu-west-1"
}

terraform {
  backend "s3" {
    bucket = "tfstate-steed"
    key    = "dev/terraform.tfstate" # Path inside the bucket
    region = "eu-west-1"
  }
}