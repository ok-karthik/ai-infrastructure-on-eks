# ==============================================================================
# Input Variables
# ==============================================================================

# Why it's needed: Sets the target AWS region for the entire infrastructure deployment.
# Changing this single value moves all resources (VPC, Subnets, EKS, EC2, KMS) to a different region.
variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

# Why it's needed: The unique identifier for your EKS cluster.
# This name is critical because:
# 1. Worker nodes use it to find the control plane during boot.
# 2. Subnets must be tagged with it so EKS load balancers know where to deploy.
# 3. Your local kubeconfig uses it to switch contexts.
variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "dev-eks-cluster"
}

# Why it's needed: The lower limit of worker nodes the EKS Managed Node Group will scale down to.
# We set this to 1 in development to save costs, but in production, this should be at least 3
# for high availability across different Availability Zones.
variable "node_group_min_size" {
  description = "Minimum number of nodes in the EKS node group"
  type        = number
  default     = 1
}

# Why it's needed: The upper limit of worker nodes the EKS Managed Node Group can scale up to.
# This prevents runaway costs by setting a hard ceiling on how many EC2 instances EKS is allowed
# to spin up when CPU/Memory limits are triggered.
variable "node_group_max_size" {
  description = "Maximum number of nodes in the EKS node group"
  type        = number
  default     = 4
}

# Why it's needed: Align the capacity of our system nodes (MNG) and controller replicas
# (e.g. Karpenter) to be set via a single common parameter.
variable "system_node_count" {
  description = "Number of system/management nodes and corresponding controller replicas (Karpenter)"
  type        = number
  default     = 1
}
