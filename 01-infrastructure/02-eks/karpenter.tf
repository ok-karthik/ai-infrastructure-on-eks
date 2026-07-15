# Tag the EKS-managed security group for Karpenter auto-discovery
resource "aws_ec2_tag" "cluster_sg_karpenter" {
  resource_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name
}

# 1. IAM Role for Karpenter Worker Nodes
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

# 2. Attach standard EKS node policies to Karpenter nodes
resource "aws_iam_role_policy_attachment" "karpenter_node_EKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.karpenter_node.name
}

resource "aws_iam_role_policy_attachment" "karpenter_node_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.karpenter_node.name
}

resource "aws_iam_role_policy_attachment" "karpenter_node_RegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.karpenter_node.name
}

resource "aws_iam_role_policy_attachment" "karpenter_node_SSM" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" # Allows SSM session shell login for node debugging
  role       = aws_iam_role.karpenter_node.name
}

# Authorize Karpenter-launched nodes to join the cluster
resource "aws_eks_access_entry" "karpenter_nodes" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.karpenter_node.arn
  type          = "EC2_LINUX" # Identifies this as standard worker nodes
}

# 1. IAM Role for Karpenter Controller App
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

# 2. IAM Policy allowing Karpenter to create/delete EC2 instances
resource "aws_iam_policy" "karpenter_controller" {
  name        = "${var.cluster_name}-karpenter-controller-policy"
  description = "Permissions for Karpenter Controller to manage EC2 instances"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateFleet",
          "ec2:RunInstances",
          "ec2:CreateLaunchTemplate",
          "ec2:Subnet",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeImages",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSubnets",
          "ec2:DeleteLaunchTemplate",
          "ec2:CreateTags",
          "ec2:DescribeTags",
          "ec2:TerminateInstances",
          "ec2:DescribeSpotPriceHistory", # Required for Spot pricing checks
          "ssm:GetParameter",
          "pricing:GetProducts", # Used by Karpenter to fetch Spot/On-Demand pricing
          "eks:DescribeCluster"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "iam:CreateInstanceProfile",
          "iam:TagInstanceProfile",
          "iam:AddRoleToInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile",
          "iam:DeleteInstanceProfile",
          "iam:GetInstanceProfile",
          "iam:ListInstanceProfiles"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.karpenter_node.arn # Karpenter must be allowed to pass the node role to EC2
      }
    ]
  })
}

# 3. Attach the policy to the controller role
resource "aws_iam_role_policy_attachment" "karpenter_controller" {
  policy_arn = aws_iam_policy.karpenter_controller.arn
  role       = aws_iam_role.karpenter_controller.name
}


resource "aws_eks_pod_identity_association" "karpenter" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "karpenter"
  service_account = "karpenter"
  role_arn        = aws_iam_role.karpenter_controller.arn
}
