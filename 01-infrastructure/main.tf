# ==============================================================================
# Module Orchestration & Dependency Tree
# ==============================================================================
# This root main.tf file coordinates the deployment of our entire cloud environment.
# Terraform resolves modules in parallel, but builds a dependency graph based on
# input/output references and explicit 'depends_on' directives.
#
locals {
  env          = "dev"
  cluster_name = ""
}

# 1. Base Network Layer
# Why it's needed: Sets up the VPC, subnets, NAT Gateways, and route tables.
# It must be provisioned first because all other compute resources need subnets to run.
module "network" {
  source       = "./01-network/"
  cluster_name = var.cluster_name
}

# 2. EKS Compute Layer
# Why it's needed: Provisions the EKS control plane and managed worker nodes.
#
# Dependency Flow:
# - vpc_id and subnet_ids are passed directly from the outputs of module.network.
#   This creates an implicit dependency: EKS will NOT begin provisioning until the
#   network subnets and VPC are fully created.
module "eks" {
  source = "./02-eks/"

  # Cluster configuration
  cluster_name = var.cluster_name
  vpc_id       = module.network.vpc_id
  subnet_ids   = module.network.private_subnet_ids

  # Node group configuration
  node_group_name             = "dev-node-group-v2"
  node_group_instance_types   = ["t3.small"]
  node_group_desired_capacity = var.system_node_count
  node_group_min_size         = var.system_node_count
  node_group_max_size         = var.system_node_count + 3
  node_group_type             = "spot"
}

# 4. Bootstrapping Layer (Argo CD GitOps Engine)
# Why it's needed: Deploys Argo CD via Helm to handle all application deployments.
#
# Dependency Flow:
# - Implicit dependencies: host, endpoint, and certificate authority data are passed
#   from module.eks.
# - Explicit depends_on: We force this module to wait for module.eks.
#   This is CRITICAL because:
#   1. EKS worker nodes must be online to run Argo CD pods.
#   2. EKS Access Entries must be active so the Helm/Kubernetes provider can authenticate
#      against the cluster using the 'terraform-admin' user.
module "bootstrap" {
  source = "../02-platform"

  cluster_name           = module.eks.cluster_name
  cluster_endpoint       = module.eks.cluster_endpoint
  cluster_ca_certificate = module.eks.cluster_certificate_authority_data
  aws_region             = var.region
  karpenter_replicas     = var.system_node_count

  depends_on = [
    module.eks
  ]
}
