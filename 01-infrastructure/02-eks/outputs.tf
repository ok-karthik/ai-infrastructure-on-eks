output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "Endpoint of the EKS cluster"
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_arn" {
  description = "ARN of the EKS cluster"
  value       = aws_eks_cluster.this.arn
}

output "node_group_name" {
  description = "Name of the node group"
  value       = aws_eks_node_group.this.node_group_name
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data required to communicate with the cluster"
  value       = aws_eks_cluster.this.certificate_authority[0].data
}
