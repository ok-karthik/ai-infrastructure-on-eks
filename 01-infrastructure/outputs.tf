output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "region" {
  description = "AWS region the cluster was deployed to"
  value       = var.region
}

output "vpc_id" {
  description = "ID of the VPC hosting the cluster"
  value       = module.network.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs used by the node group and by Karpenter"
  value       = module.network.private_subnet_ids
}

output "configure_kubectl" {
  description = "Command to point your local kubectl at this cluster"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}
