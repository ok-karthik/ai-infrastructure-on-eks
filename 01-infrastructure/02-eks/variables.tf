variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for the EKS cluster"
  type        = string
}

variable "subnet_ids" {
  description = "List of subnet IDs for the EKS cluster"
  type        = list(string)
}

variable "node_group_name" {
  description = "Name of the node group"
  type        = string
}

variable "node_group_instance_types" {
  description = "List of instance types for the node group"
  type        = list(string)
}

variable "node_group_desired_capacity" {
  description = "Desired number of nodes in the node group"
  type        = number
}

variable "node_group_min_size" {
  description = "Minimum number of nodes in the node group"
  type        = number
}

variable "node_group_max_size" {
  description = "Maximum number of nodes in the node group"
  type        = number
}

variable "node_group_type" {
  description = "Type of node group (e.g., spot, on-demand)"
  type        = string
  default     = "on-demand"
}
