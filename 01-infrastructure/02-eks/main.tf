# ==============================================================================
# KMS Key for EKS Secret Envelope Encryption
# ==============================================================================
# Why it's needed: Encrypts Kubernetes Secrets (e.g. database passwords, API tokens,
# TLS private certificates) at rest inside the EKS cluster's internal storage (etcd).
# EKS uses "Envelope Encryption": Kubernetes encrypts the secret payload using a local
# data encryption key (DEK), and then AWS KMS encrypts that DEK using the Customer
# Managed Key (CMK) defined here.
#
# What happens without it: EKS defaults to using AWS-managed keys. While technically
# encrypted, using a Customer Managed Key (CMK) is a security best practice because:
# 1. It allows granular key policy control (defining exactly who/what can decrypt EKS secrets).
# 2. It supports audit logging via AWS CloudTrail (showing exactly when EKS decrypted a secret).
# 3. It allows manual key rotation and key revocation in case of an incident.
# Without any encryption config, secrets in etcd would be stored in plaintext or basic base64.
# resource "aws_kms_key" "eks" {
#   description             = "KMS Customer Managed Key for EKS etcd secrets envelope encryption"
#   deletion_window_in_days = 7    # If deleted, wait 7 days before permanent destruction (allows recovery if accidental)
#   enable_key_rotation     = true # Automatically rotates the backing key material once a year (compliance requirement)
# 
#   tags = {
#     Name = "${var.cluster_name}-eks-kms-key"
#   }
# }
# 
# # Why it's needed: Creates a human-readable name (alias) for the KMS key.
# # What happens without it: You would have to reference the key by its long UUID or ARN,
# # which is hard to read and manage in other configurations or CLI commands.
# resource "aws_kms_alias" "eks" {
#   name          = "alias/${var.cluster_name}-eks-key"
#   target_key_id = aws_kms_key.eks.key_id
# }

# ==============================================================================
# EKS Cluster Control Plane Configuration
# ==============================================================================
# Why it's needed: The heart of the EKS cluster. It provisions the Kubernetes Control
# Plane (API Server, scheduler, controller manager, etcd) managed by AWS.
# What happens without it: You do not have a Kubernetes cluster.
resource "aws_eks_cluster" "this" {
  name = var.cluster_name

  # Why it's needed: Configures EKS to use EKS Access Entries (AWS IAM native API)
  # instead of the legacy 'aws-auth' ConfigMap. EKS Access Entries allow you to grant
  # Kubernetes admin/view access directly through AWS IAM permissions in Terraform.
  #
  # What happens without it: If set to "CONFIG_MAP" or omitted, you must manage access
  # by editing a Kubernetes ConfigMap. If you make a typo or syntax error in that ConfigMap,
  # the entire cluster immediately locks you out, and you cannot fix it without deleting
  # the cluster or using the creator's IAM credentials to bypass it.
  access_config {
    authentication_mode = "API"
  }

  # Why it's needed: Specifies the EKS Service IAM Role that EKS uses to call other
  # AWS services (like EC2, VPC, ELB) on your behalf.
  role_arn = aws_iam_role.cluster.arn
  version  = "1.35" # Specifies the Kubernetes version. 1.35 is a modern EKS release.

  # Why it's needed: Configures network communication for the EKS API Server endpoint.
  # subnet_ids: EKS deploys control plane cross-account ENIs in these subnets to talk to nodes.
  #
  # endpoint_private_access = true: Enables direct, secure VPC routing from worker nodes
  # to the EKS control plane. Traffic stays within the AWS private network and never
  # exits to the public internet, reducing latency and avoiding data transit costs.
  #
  # endpoint_public_access = true: Exposes the Kubernetes API endpoint to the internet
  # so you can run 'kubectl' commands from your local computer without a VPN or bastion host.
  #
  # What happens without it:
  # - If private access is false: Nodes must route traffic through the NAT Gateway and
  #   out to the public internet to communicate with the API Server. This increases cost,
  #   adds latency, and breaks if the NAT Gateway goes down.
  # - If public access is false: You cannot run 'kubectl' locally. You would need to set
  #   up an SSH Bastion host or an AWS Client VPN inside the VPC to access the cluster.
  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  # Why it's needed: Enables EKS Control Plane diagnostic logging in Amazon CloudWatch.
  # - api: API Server requests (records all administrative traffic).
  # - audit: Individual user/system actions inside the cluster (crucial for compliance).
  # - authenticator: IAM-to-Kubernetes login mapping events (helps debug auth failures).
  # - controllerManager: Core controller operations (managing replication, nodes, namespaces).
  # - scheduler: Pod scheduling decisions (helps debug why a pod is stuck in Pending).
  #
  # What happens without it: If the control plane malfunctions or someone performs
  # unauthorized actions inside the cluster, you will have zero log history or audit trail,
  # making debugging and security compliance impossible.
  # Set to [] in development to speed up cluster creation and destruction.
  enabled_cluster_log_types = []

  # Why it's needed: Connects the KMS key defined above to EKS for encrypting secrets.
  # What happens without it: Secrets inside the Kubernetes etcd database will not be
  # encrypted at rest using your Customer Managed Key.
  # Commented out in development to speed up cluster creation and destruction.
  # encryption_config {
  #   provider {
  #     key_arn = aws_kms_key.eks.arn
  #   }
  #   resources = ["secrets"]
  # }

  # Why this depends_on is critical:
  # During creation: EKS needs the IAM role policy attachment to exist BEFORE it boots.
  # During destruction: EKS must be deleted BEFORE the IAM policy is detached.
  # If the policy is detached first, the EKS service loses permission to clean up
  # the security groups and Network Interfaces (ENIs) it created in your VPC,
  # causing the entire Terraform destroy run to hang and fail with orphaned resources.
  depends_on = [
    aws_iam_role_policy_attachment.cluster_AmazonEKSClusterPolicy,
  ]
}

# ==============================================================================
# EKS Cluster Control Plane IAM Role
# ==============================================================================
# Why it's needed: The IAM role assumed by the EKS control plane service.
# principal "eks.amazonaws.com" allows the EKS service to assume this role.
# sts:TagSession allows EKS to apply tags to temporary session credentials (useful for tracking).
#
# What happens without it: The EKS service cannot assume any role, cannot create cross-account
# ENIs in your VPC, cannot configure security groups, and the cluster creation fails.
resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-eks-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
      },
    ]
  })
}

# Why it's needed: Attaches the AWS-managed "AmazonEKSClusterPolicy" to the cluster role.
# This policy grants EKS the permissions to create ENIs, describe VPC configuration,
# and provision load balancers.
#
# What happens without it: EKS will fail to initialize because it lacks permissions
# to create the ENIs needed for control plane-to-node communication.
resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSClusterPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster.name
}

# ==============================================================================
# Node Group IAM Role
# ==============================================================================
# Why it's needed: This role is assumed by the EC2 instances (worker nodes) in EKS.
# The trust relationship allows the "ec2.amazonaws.com" service to assume this role.
#
# What happens without it: The EC2 instances boot up but cannot authenticate with EKS
# or download necessary software/agents from AWS, so they never join the cluster.
resource "aws_iam_role" "node_group" {
  name = "${var.cluster_name}-eks-node-group-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })
}

# Why it's needed: Grants the worker nodes permission to connect to EKS, update
# node status, pull configuration, and send heartbeats (kubelet-to-API communication).
#
# What happens without it: Nodes boot but stay in the "NotReady" state inside Kubernetes
# because kubelet cannot authenticate with the EKS API server.
resource "aws_iam_role_policy_attachment" "node_group_AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node_group.name
}

# Why it's needed: Grants the VPC CNI agent (aws-node pod running on the nodes) permissions
# to allocate, describe, create, attach, and detach Elastic Network Interfaces (ENIs)
# and private IP addresses in your VPC.
#
# What happens without it: The VPC CNI plugin fails. Pods scheduled on the nodes cannot
# get private IP addresses from the VPC and remain permanently stuck in "ContainerCreating".
resource "aws_iam_role_policy_attachment" "node_group_AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node_group.name
}

# Why it's needed: Grants the node's container runtime (containerd) read-only access
# to Amazon ECR. This is required so the nodes can pull system images (like CoreDNS, kube-proxy)
# as well as your custom application container images from private ECR repositories.
#
# What happens without it: Worker nodes cannot pull any private container images,
# resulting in "ImagePullBackOff" or "ErrImagePull" errors for your applications.
resource "aws_iam_role_policy_attachment" "node_group_AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.node_group.name
}

# ==============================================================================
# Managed Node Group
# ==============================================================================
# Why it's needed: Defines the physical/virtual worker nodes (EC2 instances) that
# run your actual application containers/pods. EKS manages their provisioning,
# OS updates, and scaling.
#
# What happens without it: You have a control plane but no compute nodes. You cannot
# run any application workloads in the cluster.
resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = var.node_group_name
  node_role_arn   = aws_iam_role.node_group.arn
  subnet_ids      = var.subnet_ids # Nodes are deployed in the private subnets for security

  # Why it's needed: Configures Auto Scaling limits for the node group.
  # - desired_size: The target number of nodes to maintain under normal conditions.
  # - max_size: The upper limit the group can scale to (e.g. during traffic spikes).
  # - min_size: The absolute minimum node count (guarantees basic availability).
  #
  # What happens without it: You cannot configure Auto Scaling. If load spikes, the node
  # group won't grow, causing pods to fail to schedule due to CPU/Memory exhaustion.
  scaling_config {
    desired_size = var.node_group_desired_capacity
    max_size     = var.node_group_desired_capacity + 2
    min_size     = 1
  }

  instance_types = var.node_group_instance_types                        # t3.micro/small for cost efficiency in dev
  capacity_type  = var.node_group_type == "spot" ? "SPOT" : "ON_DEMAND" # SPOT saves ~70% cost

  # Explicit dependencies ensure IAM roles and policies are fully attached BEFORE EC2
  # instances attempt to boot and join the EKS cluster.
  depends_on = [
    aws_iam_role_policy_attachment.node_group_AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.node_group_AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.node_group_AmazonEC2ContainerRegistryReadOnly,
  ]

  # Why it's needed: In Terraform, if you update settings that force node group replacement
  # (like AMI updates or changing instance types), Terraform's default behavior is to
  # DELETE the old node group first, then create the new one. This causes a complete
  # service outage.
  #
  # 'create_before_destroy = true' forces Terraform to boot the new node group and ensure
  # it is healthy BEFORE tearing down the old one, providing zero-downtime upgrades.
  lifecycle {
    create_before_destroy = true
  }
}


# ==============================================================================
# Core EKS Addons
# ==============================================================================

# Why it's needed: Installs and configures the AWS VPC CNI plugin (aws-node DaemonSet).
# The VPC CNI is responsible for giving pods native, private IP addresses directly from
# your VPC subnets (making pods first-class network citizens in the VPC).
#
# Configuration Values explained:
# - ENABLE_PREFIX_DELEGATION = "true": Enables assigning /28 prefix blocks (16 IPs) to
#   network interfaces instead of single secondary IPs. This raises the pod limit per node
#   dramatically (e.g. from 11 pods to 110 pods on t3.small).
# - AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG = "false": Disables Custom Networking. Pods get IPs
#   from the node's subnet. If set to true, you must define secondary CIDRs (like 100.64.0.0/10)
#   and configure matching CRDs first, otherwise the CNI hangs.
# - WARM_PREFIX_TARGET = "1": Pre-allocates only 1 extra /28 prefix block in reserve.
#   Without this, the CNI aggressively pre-allocates multiple blocks, instantly consuming
#   and wasting all available IP addresses in your subnet (IP address exhaustion).
#
# What happens without this addon: Pods cannot get IP addresses, and EKS cannot route
# any network traffic between pods, nodes, or the internet.
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  configuration_values = jsonencode({
    env = {
      ENABLE_PREFIX_DELEGATION           = "true"
      AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG = "false"
      WARM_PREFIX_TARGET                 = "1"
    }
  })
}

# Why it's needed: Deploys CoreDNS in the cluster. CoreDNS handles internal DNS resolution
# within Kubernetes (e.g., allowing pod 'A' to resolve service 'B' by its service name
# 'http://my-service.my-namespace.svc.cluster.local').
#
# What happens without it: DNS resolution fails inside the cluster. Pods will fail to
# connect to other pods, services, or external internet domains using names.
#
# Why depends_on EKS Node Group: CoreDNS pods require actual worker nodes to run on.
# We must ensure the node group exists first, or the CoreDNS addon installation will hang.
resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  depends_on = [
    aws_eks_node_group.this
  ]
}

# Why it's needed: Deploys the kube-proxy agent on every node. kube-proxy manages network
# rules (using iptables or IPVS) on the host nodes to route connection requests sent to
# Kubernetes 'Service' objects to the correct backing pods.
#
# What happens without it: Service load balancing breaks. If you create a service,
# traffic sent to its IP address will be dropped, and pods won't be able to communicate.
resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
}

# Why it's needed: Installs the EKS Pod Identity Agent DaemonSet on the nodes.
# EKS Pod Identity maps AWS IAM roles directly to Kubernetes Service Accounts. If a pod
# needs to access an AWS resource (like S3 or DynamoDB), you associate an IAM role with
# its Service Account, and this agent handles token exchange automatically and securely.
#
# What happens without it: Pods cannot use AWS Pod Identity. You would have to implement
# the legacy IAM Roles for Service Accounts (IRSA), which requires creating OIDC providers,
# writing complex trust policy JSONs, and managing cross-account configurations.
resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "eks-pod-identity-agent"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
}


