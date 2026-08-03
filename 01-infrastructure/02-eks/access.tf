# ==============================================================================
# EKS Cluster Authorization & Access Entries
# ==============================================================================
# Note: EKS API authentication is decoupled from AWS IAM by default. Even if an IAM
# principal has AdministratorAccess in AWS, they CANNOT access EKS/kubectl unless
# they are explicitly registered in EKS Access Entries and bound to an EKS Access Policy.

# Resolve the identity Terraform is currently running as. This is what we grant
# cluster-admin to, so the configuration works for any operator without editing
# a hardcoded IAM user name into the repository.
data "aws_caller_identity" "current" {}

# Assumed-role sessions surface as
# arn:aws:sts::<account>:assumed-role/<role-name>/<session-name>, but EKS Access
# Entries require the underlying IAM role ARN
# (arn:aws:iam::<account>:role/<role-name>). Normalize the two forms here so the
# module works whether you authenticate as an IAM user or via an assumed role
# (SSO, CI/CD, `aws sts assume-role`).
locals {
  caller_arn_parts = split("/", data.aws_caller_identity.current.arn)

  is_assumed_role = startswith(data.aws_caller_identity.current.arn, "arn:aws:sts::") && strcontains(data.aws_caller_identity.current.arn, ":assumed-role/")

  normalized_caller_arn = local.is_assumed_role ? "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.caller_arn_parts[1]}" : data.aws_caller_identity.current.arn

  # var.cluster_admin_principal_arn wins when set, so CI or a shared team role can
  # be granted admin independently of whoever ran the apply.
  cluster_admin_arn = coalesce(var.cluster_admin_principal_arn, local.normalized_caller_arn)
}

# Register the administrating principal in the cluster's access entry list.
# Why it's needed: without an access entry, kubectl and the Helm provider return
# authentication errors even for an AWS account administrator.
resource "aws_eks_access_entry" "cluster_admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = local.cluster_admin_arn
  type          = "STANDARD"
}

# Bind the AWS-managed cluster admin policy to that access entry.
# Why it's needed: an access entry only establishes *identity*. Without a policy
# association the principal authenticates successfully but every API call is
# rejected with 'Forbidden' because it holds no Kubernetes RBAC permissions.
resource "aws_eks_access_policy_association" "cluster_admin" {
  cluster_name  = aws_eks_cluster.this.name
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  principal_arn = aws_eks_access_entry.cluster_admin.principal_arn

  access_scope {
    type = "cluster"
  }
}

# ==============================================================================
# Optional: Additional Admin Principals
# ==============================================================================
# Why it's needed: real teams need more than one break-glass admin. This lets you
# add teammates or an automation role without editing the module.
#
# Deliberately NOT granting the account root principal cluster-admin: root should
# never be used for day-to-day access, and an access entry for it widens the blast
# radius of a root credential compromise for no operational benefit.
resource "aws_eks_access_entry" "additional_admins" {
  for_each = toset(var.additional_cluster_admin_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "additional_admins" {
  for_each = aws_eks_access_entry.additional_admins

  cluster_name  = aws_eks_cluster.this.name
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  principal_arn = each.value.principal_arn

  access_scope {
    type = "cluster"
  }
}
