variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "cluster_endpoint" {
  description = "API server endpoint of the EKS cluster, passed to Karpenter for node bootstrap"
  type        = string
}

variable "aws_region" {
  description = "AWS region the cluster lives in, used for `aws eks update-kubeconfig`"
  type        = string
}

# ==============================================================================
# Chart Versions
# ==============================================================================
# Every chart is pinned. An unpinned chart means two applies a week apart install
# different software from identical code.

variable "argocd_chart_version" {
  description = "argo-cd Helm chart version (argoproj/argo-helm)"
  type        = string
  default     = "10.2.2"
}

variable "karpenter_version" {
  description = "Karpenter chart version. The karpenter and karpenter-crd charts must be kept on the same version."
  type        = string
  default     = "1.13.0"
}

variable "gpu_operator_version" {
  description = "NVIDIA GPU Operator Helm chart version"
  type        = string
  default     = "v26.3.3"
}

# ==============================================================================
# Platform Configuration
# ==============================================================================

variable "karpenter_replicas" {
  description = "Replica count for the Karpenter controller. 1 is fine for dev; use 2 in production so a node loss does not stop provisioning."
  type        = number
  default     = 1
}

variable "argocd_enable_server" {
  description = "Run the Argo CD API server and web UI. Off by default so the install fits on a single t3.small system node; turn it on to use the dashboard or the argocd CLI."
  type        = bool
  default     = false
}

variable "install_gpu_operator" {
  description = "Install the NVIDIA GPU Operator"
  type        = bool
  default     = true
}

variable "gpu_driver_managed_by_operator" {
  description = "Let the GPU Operator install the NVIDIA driver and container toolkit. Must stay false while the GPU EC2NodeClass uses the EKS NVIDIA-optimized AMI, which ships both already; set it to true only if you switch to a plain AL2023 AMI."
  type        = bool
  default     = false
}

variable "gpu_time_slicing_replicas" {
  description = "Time-sliced virtual GPUs advertised per physical GPU. 1 disables time slicing. Shares compute only - VRAM is not isolated between replicas."
  type        = number
  default     = 4

  validation {
    condition     = var.gpu_time_slicing_replicas >= 1 && var.gpu_time_slicing_replicas <= 48
    error_message = "gpu_time_slicing_replicas must be between 1 and 48."
  }
}
