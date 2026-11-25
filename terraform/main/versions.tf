terraform {
  # 1.10+ for S3 native state locking (use_lockfile).
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
    # awscc (Cloud Control) holds the AWS DevOps Agent resources.
    # >= 1.98.0 is required for awscc_devopsagent_asset and _trigger.
    awscc = {
      source  = "hashicorp/awscc"
      version = ">= 1.98.0, < 2.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4, < 3.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.11, < 1.0"
    }
  }

  # Configured at init time from project.env: see scripts/config.py backend.
  backend "s3" {}
}

provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.aws_account_id]
  default_tags {
    tags = var.tags
  }
}

provider "awscc" {
  region = var.aws_region
}
