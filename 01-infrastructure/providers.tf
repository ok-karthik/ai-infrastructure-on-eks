# ==============================================================================
# Terraform Core Configuration & Providers
# ==============================================================================
# Why it's needed: Declares the external plugins (providers) required to provision
# infrastructure. Terraform downloads these during 'terraform init'.
terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0" # Restricts the AWS provider to 6.x to prevent breaking syntax changes
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17" # Helm provider 3.x changes the `set`/`kubernetes` block syntax
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }

  # State is local by design for this learning/demo environment: it keeps the
  # bootstrap free of an S3 bucket and DynamoDB table you would otherwise have to
  # create out-of-band. For any shared or production use, switch to a remote
  # backend so state is locked and not lost with the laptop:
  #
  # backend "s3" {
  #   bucket       = "<your-tf-state-bucket>"
  #   key          = "ai-infrastructure-on-eks/terraform.tfstate"
  #   region       = "us-east-1"
  #   encrypt      = true
  #   use_lockfile = true # S3-native locking; replaces the old DynamoDB table
  # }
}

# Why it's needed: Configures the AWS provider and sets the target AWS region.
# Driven by var.region so the region is defined in exactly one place.
provider "aws" {
  region = var.region

  # Applied to every resource that supports tagging. Makes cost attribution and
  # "what is this orphaned ENI" cleanup possible after a failed destroy.
  default_tags {
    tags = {
      Project     = "ai-infrastructure-on-eks"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}

# Why it's needed: Configures the Helm provider to install charts into the cluster.
#
# Authentication settings:
# - host / cluster_ca_certificate: how Helm reaches and verifies the EKS API server.
# - exec block: generates a short-lived Kubernetes token via the local AWS CLI
#   ('aws eks get-token'), using your current AWS credentials. No static kubeconfig
#   or long-lived token is stored anywhere.
#
# What happens without it:
# - Without the CA cert: TLS verification against the API server fails.
# - Without the exec block: every Helm operation returns 401 Unauthorized.
#
# Known limitation: these attributes are resolved from module.eks outputs, which do
# not exist until the cluster is created. On a completely fresh apply Terraform
# handles this correctly because module.bootstrap depends_on module.eks, but if you
# ever see "Kubernetes cluster unreachable" on the first run, re-run apply.
provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}
