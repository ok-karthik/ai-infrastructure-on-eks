# ==============================================================================
# Module Orchestration & Dependency Tree
# ==============================================================================
# This root main.tf coordinates the deployment of the entire environment.
# Terraform resolves modules in parallel, but builds a dependency graph from
# input/output references and explicit 'depends_on' directives.

# 1. Base Network Layer
# Why it's needed: Sets up the VPC, subnets, NAT Gateway, and route tables.
# It must be provisioned first because all other compute resources need subnets to run.
module "network" {
  source       = "./01-network/"
  cluster_name = var.cluster_name
}

# 2. EKS Compute Layer
# Why it's needed: Provisions the EKS control plane and managed worker nodes.
#
# Dependency Flow:
# - subnet_ids is passed directly from the outputs of module.network, creating an
#   implicit dependency: EKS will not begin provisioning until the network exists.
module "eks" {
  source = "./02-eks/"

  # Cluster configuration
  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version
  subnet_ids      = module.network.private_subnet_ids

  # Node group configuration. This managed node group only hosts controllers
  # (Karpenter, Argo CD, GPU Operator control plane); all workload capacity is
  # provisioned dynamically by Karpenter.
  node_group_name             = "${var.cluster_name}-system"
  node_group_instance_types   = var.system_node_instance_types
  node_group_desired_capacity = var.system_node_count
  node_group_min_size         = var.node_group_min_size
  node_group_max_size         = var.node_group_max_size
  node_group_type             = "spot"

  # Security posture toggles. Both default to the cheap/fast dev setting; see
  # variables.tf for what to turn on for a production-like cluster.
  enable_secrets_encryption = var.enable_secrets_encryption
  enabled_cluster_log_types = var.enabled_cluster_log_types
}

# 3. Platform Bootstrapping Layer (Argo CD, Karpenter, GPU Operator)
# Why it's needed: Installs the platform controllers via Helm on top of the cluster.
#
# Dependency Flow:
# - Implicit: cluster endpoint and name are passed from module.eks.
# - Explicit depends_on module.eks: the Helm provider authenticates against the
#   cluster at apply time, so the control plane, the node group, and the EKS
#   Access Entry for this operator must all exist before any release is installed.
module "bootstrap" {
  source = "../02-platform"

  cluster_name       = module.eks.cluster_name
  cluster_endpoint   = module.eks.cluster_endpoint
  aws_region         = var.region
  karpenter_replicas = var.system_node_count

  # GPU platform configuration
  gpu_time_slicing_replicas = var.gpu_time_slicing_replicas
  install_gpu_operator      = var.install_gpu_operator

  depends_on = [
    module.eks
  ]
}
