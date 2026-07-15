variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "cluster_endpoint" {
  description = "Endpoint of the EKS cluster"
  type        = string
}

variable "cluster_ca_certificate" {
  description = "Base64 encoded certificate data required to communicate with the cluster"
  type        = string
}

variable "aws_region" {
  description = "AWS Region"
  type        = string
}

variable "karpenter_replicas" {
  description = "Number of replicas for the Karpenter controller deployment"
  type        = number
  default     = 1
}

