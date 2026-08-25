terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }

  backend "s3" {
    bucket         = "jdbank-terraform-state-efp"
    key            = "capstone/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "jdbank-terraform-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "jdbank-capstone"
      ManagedBy   = "terraform"
      Environment = var.environment
    }
  }
}