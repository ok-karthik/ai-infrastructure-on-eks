# Provider requirements for the network module. Declared per-module so the module
# is self-describing and can be consumed independently of this root configuration.
terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
