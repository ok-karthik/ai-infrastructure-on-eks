# Provider requirements for the EKS module.
#
# The http provider is used in alb-controller-iam.tf to fetch the upstream AWS Load
# Balancer Controller IAM policy document at a pinned release tag.
terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }
}
