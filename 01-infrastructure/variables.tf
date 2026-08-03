# ==============================================================================
# Input Variables
# ==============================================================================

# Why it's needed: Sets the target AWS region for the entire deployment.
# Changing this single value moves all resources (VPC, Subnets, EKS, KMS) elsewhere.
#
# NOTE: if you change this, also update the karpenter.sh/discovery tag values and
# the `role` field in 02-platform/karpenter/*.yaml, which are matched by name.
variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

# Why it's needed: The unique identifier for your EKS cluster.
# This name is critical because:
# 1. Worker nodes use it to find the control plane during boot.
# 2. Subnets are tagged with it so EKS and Karpenter can discover them.
# 3. Your local kubeconfig uses it to switch contexts.
#
# NOTE: the Karpenter manifests in 02-platform/karpenter/ reference this name
# literally (subnet/security group discovery tags and the node IAM role name).
# If you change it, update those manifests to match.
variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "dev-eks-cluster"
}

variable "cluster_version" {
  description = "Kubernetes minor version for the EKS control plane"
  type        = string
  default     = "1.35"
}

# ==============================================================================
# System Node Group Sizing
# ==============================================================================
# This managed node group exists only to run platform controllers. Workload
# capacity comes from Karpenter, which is why these numbers are small.

variable "system_node_count" {
  description = "Desired number of system/management nodes, and the matching replica count for the Karpenter controller"
  type        = number
  default     = 1
}

variable "system_node_instance_types" {
  description = "Instance types for the system managed node group"
  type        = list(string)
  default     = ["t3.small"]
}

variable "node_group_min_size" {
  description = "Minimum number of nodes in the system node group. Set to at least 3 across AZs for production HA."
  type        = number
  default     = 1
}

variable "node_group_max_size" {
  description = "Maximum number of nodes in the system node group. Caps runaway EC2 cost."
  type        = number
  default     = 4
}

# ==============================================================================
# Security Posture
# ==============================================================================
# Both default to the cheap, fast-teardown dev setting. Flip them on for anything
# resembling production.

variable "enable_secrets_encryption" {
  description = "Create a customer-managed KMS key and enable EKS envelope encryption for Kubernetes Secrets. Off by default because the key costs money and slows cluster create/destroy."
  type        = bool
  default     = false
}

variable "enabled_cluster_log_types" {
  description = "EKS control plane log types shipped to CloudWatch. Empty by default to avoid ingestion charges on a cluster that is destroyed daily. Production: [\"api\", \"audit\", \"authenticator\", \"controllerManager\", \"scheduler\"]."
  type        = list(string)
  default     = []
}

# ==============================================================================
# GPU Platform
# ==============================================================================

variable "install_gpu_operator" {
  description = "Install the NVIDIA GPU Operator. Set to false if you only want to exercise the CPU-only Karpenter path and avoid GPU instance cost."
  type        = bool
  default     = true
}

variable "gpu_time_slicing_replicas" {
  description = "Number of time-sliced virtual GPUs to advertise per physical GPU. 1 disables time slicing. Note that time slicing shares compute but does NOT isolate VRAM."
  type        = number
  default     = 4
}
