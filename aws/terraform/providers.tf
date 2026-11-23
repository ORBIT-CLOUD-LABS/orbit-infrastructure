terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # [부트스트랩 이후 활성화] 새 계정에 state 전용 S3 버킷 생성 후 주석을 해제하고 terraform init -migrate-state 실행
  # backend "s3" {
  #   bucket       = "<TFSTATE_BUCKET_NAME>"
  #   key          = "orbit/aws/terraform.tfstate"
  #   region       = "ap-northeast-2"
  #   encrypt      = true
  #   use_lockfile = true
  # }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile != "" ? var.aws_profile : null

  default_tags {
    tags = {
      Project     = "orbit"
      Environment = var.environment
      ManagedBy   = "terraform"
      Owner       = var.owner
    }
  }
}
