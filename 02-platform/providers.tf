# This module is consumed as a child module by 01-infrastructure and inherits the
# configured helm provider from the root. It declares its own provider requirements
# (versions only, no configuration) so the constraints are validated here too.
terraform {
  required_version = ">= 1.5"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
  }
}
