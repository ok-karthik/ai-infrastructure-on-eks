variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes minor version for the EKS control plane. Verify it is still in standard support before applying: `aws eks describe-cluster-versions --query 'clusterVersions[].clusterVersion'`. Keep in sync with the version badge in README.md."
  type        = string
  default     = "1.35"
}

variable "subnet_ids" {
  description = "Private subnet IDs used for the control plane ENIs and the managed node group"
  type        = list(string)
}

variable "node_group_name" {
  description = "Name of the managed node group that hosts system/controller pods"
  type        = string
}

variable "node_group_instance_types" {
  description = "Instance types the managed node group may launch"
  type        = list(string)
}

variable "node_group_desired_capacity" {
  description = "Desired number of nodes in the managed node group"
  type        = number
}

variable "node_group_min_size" {
  description = "Minimum number of nodes in the managed node group"
  type        = number
}

variable "node_group_max_size" {
  description = "Maximum number of nodes in the managed node group"
  type        = number

  validation {
    condition     = var.node_group_max_size >= var.node_group_min_size
    error_message = "node_group_max_size must be greater than or equal to node_group_min_size."
  }
}

variable "node_group_type" {
  description = "Capacity type for the managed node group: 'spot' or 'on-demand'"
  type        = string
  default     = "on-demand"

  validation {
    condition     = contains(["spot", "on-demand"], var.node_group_type)
    error_message = "node_group_type must be either 'spot' or 'on-demand'."
  }
}

variable "enable_secrets_encryption" {
  description = "Create a customer-managed KMS key and enable EKS envelope encryption for Kubernetes Secrets. Disabled by default in dev because the key adds cost and slows cluster create/destroy; enable it for anything production-like."
  type        = bool
  default     = false
}

variable "enabled_cluster_log_types" {
  description = "EKS control plane log types to ship to CloudWatch. Empty in dev to keep cost down and speed up teardown; use [\"api\", \"audit\", \"authenticator\", \"controllerManager\", \"scheduler\"] for production."
  type        = list(string)
  default     = []
}

variable "cluster_admin_principal_arn" {
  description = "IAM principal ARN to grant cluster-admin. Defaults to the identity running Terraform, which is what you want for a single-operator setup."
  type        = string
  default     = null
}

variable "additional_cluster_admin_arns" {
  description = "Extra IAM principal ARNs (teammates, CI roles) to grant cluster-admin"
  type        = list(string)
  default     = []
}

variable "alb_controller_version" {
  description = "Release tag of kubernetes-sigs/aws-load-balancer-controller to source the IAM policy document from. Pinned rather than tracking 'main' so IAM permissions only change when you change them."
  type        = string
  default     = "v3.4.3"
}
