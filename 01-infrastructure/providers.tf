# ==============================================================================
# Terraform Core Configuration & Providers
# ==============================================================================
# Why it's needed: Declares the external plugins (providers) required to provision
# infrastructure. Terraform downloads these plugins automatically during 'terraform init'.
#
# What happens without it: Terraform will not know how to translate your code into
# AWS or Helm API calls, and will fail to execute.
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0" # Restricts the AWS provider to version 6.x to prevent breaking syntax changes
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12" # Restricts the Helm provider to version 2.12.x
    }
  }
}

# Why it's needed: Configures the AWS provider and sets the target AWS region.
# All aws_* resources declared in this project will deploy to this region.
provider "aws" {
  region = "us-east-1"
}

# Why it's needed: Configures the Helm provider to deploy Kubernetes packages (charts).
# To talk to the cluster, Helm needs to authenticate with the EKS API Server.
#
# Authentication settings:
# - host: The API endpoint URL of your EKS cluster control plane.
# - cluster_ca_certificate: The certificate authority data used to verify EKS API Server identity.
# - exec block: Instructs Helm to dynamically generate a short-lived Kubernetes login token
#   using the local AWS CLI ('aws eks get-token'). This executes locally using your current
#   AWS IAM role/user credentials.
#
# What happens without it:
# - Without CA cert: Helm will fail to verify EKS identity, raising TLS security warnings or errors.
# - Without Exec block: Helm cannot authenticate with Kubernetes. It will return 401 Unauthorized
#   errors, preventing any Helm charts (like Argo CD or Karpenter) from being installed.
provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
      command     = "aws"
    }
  }
}
