# ==============================================================================
# AWS Availability Zones & Region Discovery
# ==============================================================================
# Why it's needed: Dynamically queries AWS to find all active Availability Zones (AZs)
# in the current region (e.g. ap-south-2a, ap-south-2b, ap-south-2c).
# What happens without it: AZs would have to be hardcoded. If an AZ goes down or is
# not available in a specific region, or if you change regions, the Terraform configuration
# will fail or be locked to a single region.
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_region" "current" {}

variable "cluster_name" {
  description = "Name of the EKS cluster for resource tagging"
  type        = string
  default     = "dev-eks-cluster"
}

locals {
  env      = "dev"
  project  = "learning-aws"
  vpc_cidr = "10.0.0.0/16" # 65,536 private IP addresses available in this VPC
  # We select the first 3 AZs for high availability. EKS requires at least 2 AZs
  # for control plane redundancy.
  azs = slice(data.aws_availability_zones.available.names, 0, 3)
}

# ==============================================================================
# Virtual Private Cloud (VPC)
# ==============================================================================
# Why it's needed: Provides a logically isolated virtual network in your AWS account.
# It forms the security and networking boundary for all EKS resources, databases, and VMs.
# What happens without it: Resources would be deployed in the AWS default VPC, which is
# shared with other default resources, lacks custom routing controls, and is generally
# exposed to the public internet by default, posing a severe security risk.
resource "aws_vpc" "main" {
  cidr_block = local.vpc_cidr

  # Enable DNS hostnames so AWS resources receive public/private DNS names (required by EKS)
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${local.project}-${local.env}-vpc"
  }
}

# ==============================================================================
# Public Subnet
# ==============================================================================
# Why it's needed: Hosts resources that must be directly reachable from the public
# internet (e.g. Internet Gateways, NAT Gateways, public load balancers).
# What happens without it: You cannot run a NAT Gateway or a public load balancer.
# Consequently, private EKS worker nodes would have no path to the public internet
# to pull container images or update software.
resource "aws_subnet" "public" {
  count             = length(local.azs) - 1 # Create 2 public subnets
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(local.vpc_cidr, 8, count.index == 0 ? 1 : 10) # 10.0.1.0/24 and 10.0.10.0/24
  availability_zone = local.azs[count.index]

  # Automatically assign public IPs to instances launched in this subnet.
  # This is required for public ingress/egress.
  map_public_ip_on_launch = true

  tags = {
    Name                     = "${local.project}-${local.env}-public-${count.index}"
    "kubernetes.io/role/elb" = "1" # Required for public ALBs
  }
}

# ==============================================================================
# Private Subnets (For EKS Nodes & Pods)
# ==============================================================================
# Why it's needed: Hosts EKS worker nodes, databases, and microservices securely.
# These subnets have no direct route from the internet; traffic must go through a
# NAT Gateway or an internal load balancer.
# What happens without it: Worker nodes would be placed in public subnets with public
# IPs, exposing them directly to internet traffic, brute force SSH scans, and zero-day exploits.
# resource "aws_subnet" "private" {
resource "aws_subnet" "private" {
  count             = length(local.azs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(local.vpc_cidr, 8, count.index == 2 ? 5 : count.index + 2) # 10.0.2.0/24, 10.0.3.0/24, and 10.0.5.0/24
  availability_zone = local.azs[count.index]

  tags = {
    Name = "${local.project}-${local.env}-private-${count.index}"
    # EKS specific tags required by EKS to discover subnets for internal load balancers
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "karpenter.sh/discovery"                    = "${var.cluster_name}"
  }
}

# ==============================================================================
# Public Route Table
# ==============================================================================
# Why it's needed: Routes traffic from the public subnet directly to the Internet Gateway
# for any destination outside the VPC (0.0.0.0/0).
# What happens without it: The public subnet will not be public. Resources inside it
# (like the NAT Gateway) will be unable to send traffic to the internet.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "${local.project}-${local.env}-public-rt"
  }
}

# ==============================================================================
# Private Route Table
# ==============================================================================
# Why it's needed: Routes egress internet traffic (0.0.0.0/0) from the private subnets
# through the NAT Gateway.
# What happens without it: Worker nodes in private subnets cannot pull images from ECR,
# connect to EKS control plane API endpoints, or call external APIs.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = {
    Name = "${local.project}-${local.env}-private-rt"
  }
}

# ==============================================================================
# Internet Gateway (IGW)
# ==============================================================================
# Why it's needed: Connects your VPC to the public internet, enabling bidirectional
# communication for resources in public subnets.
# What happens without it: The VPC is completely isolated from the internet. Even if
# you configure NAT Gateways or public subnets, no packets can ever enter or exit the VPC.
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.project}-${local.env}-igw"
  }
}

# ==============================================================================
# Elastic IP (EIP) for NAT Gateway
# ==============================================================================
# Why it's needed: Provides a static, persistent public IP address for the NAT Gateway.
# When private instances send traffic to the internet, they appear to originate from this static IP.
# What happens without it: You cannot create a NAT Gateway. NAT Gateways require a
# static EIP so that external services can whitelist/identify the outbound traffic source.
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${local.project}-${local.env}-nat-eip"
  }
}

# ==============================================================================
# NAT Gateway
# ==============================================================================
# Why it's needed: Performs Source Network Address Translation (SNAT). It allows EKS
# worker nodes and pods in private subnets to send requests outbound to the internet,
# but prevents anyone on the internet from initiating inbound connections to them.
# What happens without it: Pods cannot connect to any external databases, SaaS APIs,
# or AWS services outside the VPC. EKS nodes will fail to download bootstrap scripts
# and join the cluster, rendering the cluster unusable.
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id # Must be placed in the public subnet to reach the IGW

  tags = {
    Name = "${local.project}-${local.env}-nat-gateway"
  }

  # To ensure proper ordering, it is best to specify that the NAT Gateway depends on the IGW.
  depends_on = [aws_internet_gateway.gw]
}

# ==============================================================================
# Route Table Associations
# ==============================================================================
# Why it's needed: Explicitly binds the subnets to their respective route tables.
# What happens without it: Subnets default to the main VPC route table (which has no
# routes to the IGW or NAT Gateway), making them completely isolated and unable to route
# internet traffic.
resource "aws_route_table_association" "public" {
  count          = length(local.azs) - 1
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ==============================================================================
# Outputs
# ==============================================================================
output "vpc_id" {
  description = "The ID of the VPC"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "The IDs of the public subnets"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "The IDs of the private subnets"
  value       = aws_subnet.private[*].id
}

output "internet_gateway_id" {
  description = "The ID of the Internet Gateway"
  value       = aws_internet_gateway.gw.id
}

output "nat_gateway_id" {
  description = "The ID of the NAT Gateway"
  value       = aws_nat_gateway.nat.id
}

output "nat_eip_allocation_id" {
  description = "The allocation ID of the NAT EIP"
  value       = aws_eip.nat.id
}
