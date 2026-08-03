# ==============================================================================
# Karpenter Discovery Tagging
# ==============================================================================
# Karpenter finds the security group to attach to nodes it launches by tag, using
# the securityGroupSelectorTerms in the EC2NodeClass. The EKS-managed cluster
# security group is created by AWS, so we tag it here rather than at creation.
resource "aws_ec2_tag" "cluster_sg_karpenter" {
  resource_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name
}

data "aws_region" "current" {}

data "aws_partition" "current" {}

# ==============================================================================
# IAM Role for Karpenter-Launched Worker Nodes
# ==============================================================================
# This is the role Karpenter passes to the EC2 instances it provisions. It is a
# standard EKS worker node role and is referenced by name in the EC2NodeClass
# manifests under 02-platform/karpenter/.
resource "aws_iam_role" "karpenter_node" {
  name = "${var.cluster_name}-karpenter-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_node_EKSWorkerNodePolicy" {
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.karpenter_node.name
}

resource "aws_iam_role_policy_attachment" "karpenter_node_CNI_Policy" {
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.karpenter_node.name
}

resource "aws_iam_role_policy_attachment" "karpenter_node_RegistryReadOnly" {
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.karpenter_node.name
}

# Allows SSM Session Manager shell access for node debugging without opening SSH
# or running a bastion host. Useful when investigating GPU driver load failures
# directly on the node.
resource "aws_iam_role_policy_attachment" "karpenter_node_SSM" {
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.karpenter_node.name
}

# Authorize Karpenter-launched nodes to join the cluster. The EC2_LINUX entry type
# tells EKS to grant these instances the standard node bootstrap permissions.
resource "aws_eks_access_entry" "karpenter_nodes" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.karpenter_node.arn
  type          = "EC2_LINUX"
}

# ==============================================================================
# IAM Role for the Karpenter Controller
# ==============================================================================
# Trusted by pods.eks.amazonaws.com rather than an OIDC provider, because this
# cluster uses EKS Pod Identity (see the association at the bottom of this file)
# instead of IRSA. Pod Identity avoids managing an OIDC provider and hand-written
# trust policy conditions.
resource "aws_iam_role" "karpenter_controller" {
  name = "${var.cluster_name}-karpenter-controller-role"

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

# ==============================================================================
# Karpenter Controller Permissions
# ==============================================================================
# Scoped to this cluster wherever the AWS API supports it. The pattern is:
#
#   - Creating things       -> require the cluster ownership tag on the REQUEST
#                              (aws:RequestTag), so Karpenter can only create
#                              resources it marks as belonging to this cluster.
#   - Mutating/deleting     -> require the ownership tag on the RESOURCE
#                              (aws:ResourceTag), so Karpenter cannot terminate
#                              instances belonging to another cluster or to a
#                              hand-managed workload in the same account.
#   - Read-only describes   -> unscoped but region-restricted; EC2 Describe* APIs
#                              do not support resource-level permissions.
#
# An unscoped ec2:TerminateInstances on "*" would let a compromised or buggy
# controller delete every EC2 instance in the account.
locals {
  karpenter_cluster_tag = "kubernetes.io/cluster/${var.cluster_name}"
}

resource "aws_iam_policy" "karpenter_controller" {
  name        = "${var.cluster_name}-karpenter-controller-policy"
  description = "Permissions for the Karpenter controller to manage EC2 capacity for ${var.cluster_name}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Launch capacity. Karpenter must be able to read the AMIs, subnets, security
      # groups and instance types it selects from before it can build a launch plan.
      {
        Sid    = "AllowScopedEC2InstanceActions"
        Effect = "Allow"
        Action = [
          "ec2:RunInstances",
          "ec2:CreateFleet",
          "ec2:CreateLaunchTemplate"
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}::image/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}::snapshot/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:security-group/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:subnet/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:capacity-reservation/*"
        ]
      },

      # Creating the actual billable resources requires the cluster ownership tag on
      # the request, which is what binds new capacity to this cluster.
      {
        Sid    = "AllowScopedEC2InstanceActionsWithTags"
        Effect = "Allow"
        Action = [
          "ec2:RunInstances",
          "ec2:CreateFleet",
          "ec2:CreateLaunchTemplate"
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:fleet/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:instance/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:volume/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:network-interface/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:launch-template/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:spot-instances-request/*"
        ]
        Condition = {
          StringEquals = {
            "aws:RequestTag/${local.karpenter_cluster_tag}" = "owned"
          }
          StringLike = {
            "aws:RequestTag/karpenter.sh/nodepool" = "*"
          }
        }
      },

      # Tagging at creation time. Restricted to the CreateAction values Karpenter
      # actually performs so this cannot be used to tag arbitrary existing resources.
      {
        Sid      = "AllowScopedResourceCreationTagging"
        Effect   = "Allow"
        Action   = "ec2:CreateTags"
        Resource = "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:*/*"
        Condition = {
          StringEquals = {
            "aws:RequestTag/${local.karpenter_cluster_tag}" = "owned"
            "ec2:CreateAction" = [
              "RunInstances",
              "CreateFleet",
              "CreateLaunchTemplate",
              "CreateVolume",
              "CreateNetworkInterface"
            ]
          }
        }
      },

      # Karpenter writes the karpenter.sh/nodeclaim and disruption-state tags onto
      # instances it already owns as nodes move through their lifecycle.
      {
        Sid      = "AllowScopedResourceTagging"
        Effect   = "Allow"
        Action   = "ec2:CreateTags"
        Resource = "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:instance/*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/${local.karpenter_cluster_tag}" = "owned"
          }
        }
      },

      # Termination and launch template cleanup, gated on the resource already
      # carrying this cluster's ownership tag.
      {
        Sid    = "AllowScopedDeletion"
        Effect = "Allow"
        Action = [
          "ec2:TerminateInstances",
          "ec2:DeleteLaunchTemplate"
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:instance/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:launch-template/*"
        ]
        Condition = {
          StringEquals = {
            "aws:ResourceTag/${local.karpenter_cluster_tag}" = "owned"
          }
        }
      },

      # EC2 Describe* APIs do not support resource-level permissions, so these are
      # restricted by region instead. ec2:DescribeSpotPriceHistory backs Karpenter's
      # Spot instance-type selection and consolidation cost comparisons.
      {
        Sid    = "AllowRegionalReadActions"
        Effect = "Allow"
        Action = [
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeImages",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSpotPriceHistory",
          "ec2:DescribeSubnets",
          "ec2:DescribeTags"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestedRegion" = data.aws_region.current.region
          }
        }
      },

      # Karpenter resolves EKS-optimized AMI IDs from SSM public parameters.
      {
        Sid      = "AllowSSMReadActions"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "arn:${data.aws_partition.current.partition}:ssm:${data.aws_region.current.region}::parameter/aws/service/*"
      },

      # On-Demand price discovery for consolidation decisions. The Pricing API is
      # global and does not support resource-level permissions.
      {
        Sid      = "AllowPricingReadActions"
        Effect   = "Allow"
        Action   = "pricing:GetProducts"
        Resource = "*"
      },

      # Karpenter reads the cluster endpoint and CA bundle to build node bootstrap
      # user data.
      {
        Sid      = "AllowAPIServerEndpointDiscovery"
        Effect   = "Allow"
        Action   = "eks:DescribeCluster"
        Resource = aws_eks_cluster.this.arn
      },

      # Karpenter manages the instance profile that wraps the node role. Scoped to
      # this cluster's tag so it cannot modify unrelated instance profiles.
      {
        Sid    = "AllowScopedInstanceProfileActions"
        Effect = "Allow"
        Action = [
          "iam:CreateInstanceProfile",
          "iam:TagInstanceProfile",
          "iam:AddRoleToInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile",
          "iam:DeleteInstanceProfile"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:iam::*:instance-profile/*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/${local.karpenter_cluster_tag}" = "owned"
          }
        }
      },

      # Reads are separated from writes because Karpenter must be able to look up an
      # instance profile before it has been tagged.
      {
        Sid    = "AllowInstanceProfileReadActions"
        Effect = "Allow"
        Action = [
          "iam:GetInstanceProfile",
          "iam:ListInstanceProfiles"
        ]
        Resource = "*"
      },

      # Restricted to exactly the node role above: Karpenter can only hand EC2 the
      # role we intend, not an arbitrary privileged role in the account.
      {
        Sid      = "AllowPassingInstanceRole"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.karpenter_node.arn
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ec2.amazonaws.com"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_controller" {
  policy_arn = aws_iam_policy.karpenter_controller.arn
  role       = aws_iam_role.karpenter_controller.name
}

# ==============================================================================
# Pod Identity Association
# ==============================================================================
# Binds the karpenter ServiceAccount in the karpenter namespace to the controller
# role above. depends_on the Pod Identity Agent addon because the association is
# only usable once the agent DaemonSet is running to serve credentials.
resource "aws_eks_pod_identity_association" "karpenter" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "karpenter"
  service_account = "karpenter"
  role_arn        = aws_iam_role.karpenter_controller.arn

  depends_on = [aws_eks_addon.pod_identity_agent]
}
