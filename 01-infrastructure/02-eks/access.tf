# ==============================================================================
# EKS Cluster Authorization & Access Entries
# ==============================================================================
# Note: EKS API authentication is decoupled from AWS IAM by default. Even if an IAM
# principal has AdministratorAccess in AWS, they CANNOT access EKS/Kubectl unless
# they are explicitly registered in EKS Access Entries and bound to an EKS Access Policy.

# 1. Fetch your current AWS account ID dynamically to construct the Root ARN.
data "aws_caller_identity" "current" {}

# 2. Create an Access Entry for your AWS Account Root user
# Why it's needed: Registers the AWS account root principal (which console/admins assume)
# in the EKS cluster mapping list.
# What happens without it: Root account users cannot view or manage EKS resources via kubectl.
resource "aws_eks_access_entry" "console_access" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
  # Let's dynamically inject the current account ID using string interpolation:
  # principal_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
  # Wait, let's use string interpolation correctly in Terraform:
  # principal_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
  type = "STANDARD"
}

# 3. Bind the Admin Policy to the Root user
# Why it's needed: Associates cluster-wide Administrator privileges inside Kubernetes RBAC
# to the Root access entry.
# What happens without it: Root users can authenticate, but all commands will fail with 'Forbidden'.
resource "aws_eks_access_policy_association" "console_admin" {
  cluster_name  = aws_eks_cluster.this.name
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  principal_arn = aws_eks_access_entry.console_access.principal_arn

  access_scope {
    type = "cluster"
  }
}

# 4. Create an Access Entry for your Terraform admin user
# Why it's needed: Registers the IAM user 'terraform-admin' (which you use locally to run
# terraform and kubectl) in the EKS cluster mapping list.
# What happens without it: Your local kubectl commands immediately return auth errors.
resource "aws_eks_access_entry" "terraform_admin_access" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/terraform-admin"
  type          = "STANDARD"
}

# 5. Bind the Admin Policy to the Terraform user
# Why it's needed: Grants full administrator rights to the 'terraform-admin' user.
# What happens without it: If set to ViewerPolicy, commands like 'kubectl get pods' or
# 'helm install' return 'Forbidden' because the user lacks write/create permissions.
resource "aws_eks_access_policy_association" "terraform_admin_policy" {
  cluster_name  = aws_eks_cluster.this.name
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  principal_arn = aws_eks_access_entry.terraform_admin_access.principal_arn

  access_scope {
    type = "cluster"
  }
}
