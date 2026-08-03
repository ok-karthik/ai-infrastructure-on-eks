# ==============================================================================
# AWS Load Balancer Controller IAM
# ==============================================================================
# NOTE: this role is provisioned but the controller itself is not installed by
# this repository. It is here so that adding the controller (via Helm, bound to
# the aws-load-balancer-controller-sa ServiceAccount below) requires no IAM work.

# 1. Fetch the official AWS Load Balancer Controller IAM Policy document.
#
# Pinned to a release tag, not `main`. Reading this from `main` means every
# `terraform apply` silently adopts whatever permissions upstream merged that
# day: the plan diff changes without any change in this repository, and an
# upstream mistake becomes an IAM grant in your account. Bump the version
# deliberately when you upgrade the controller.
data "http" "lbc_iam_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${var.alb_controller_version}/docs/install/iam_policy.json"

  # Fail loudly at plan time instead of writing an HTML error page into an IAM policy.
  request_headers = {
    Accept = "application/json"
  }

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "Failed to fetch the AWS Load Balancer Controller IAM policy for version ${var.alb_controller_version} (HTTP ${self.status_code}). Check that the tag exists in kubernetes-sigs/aws-load-balancer-controller."
    }
  }
}

# 2. Create the IAM Policy in AWS
resource "aws_iam_policy" "alb_controller" {
  name        = "${var.cluster_name}-alb-controller-policy"
  description = "Permissions for AWS Load Balancer Controller to manage ALBs/NLBs"
  policy      = data.http.lbc_iam_policy.response_body
}

# 3. Create the IAM Role with the Pod Identity Trust Policy
resource "aws_iam_role" "alb_controller" {
  name = "${var.cluster_name}-alb-controller-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "pods.eks.amazonaws.com"
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
      }
    ]
  })
}

# 4. Attach the policy to the role
resource "aws_iam_role_policy_attachment" "alb_controller_attach" {
  policy_arn = aws_iam_policy.alb_controller.arn
  role       = aws_iam_role.alb_controller.name
}

# 5. Create the EKS Pod Identity Association
resource "aws_eks_pod_identity_association" "alb_controller" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller-sa"
  role_arn        = aws_iam_role.alb_controller.arn
}
