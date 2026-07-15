# AI Agent Guidelines (AGENTS.md)

This file contains rules, guidelines, common commands, and context for AI coding assistants working on this repository.

---

## 1. Project Context & Architecture

This repository is a production-grade blueprint for AI Infrastructure engineering, demonstrating Amazon EKS, Karpenter, and NVIDIA GPU workload orchestration. The configuration is organized as follows:

*   **`01-infrastructure/`**: Core infrastructure layers managed by Terraform:
    *   `01-network`: Base VPC, private/public subnets, NAT Gateway, Route Tables.
    *   `02-eks`: EKS Control Plane, Managed system node group, IAM OIDC provider, Access Entries, and Karpenter controller node roles.
*   **`02-platform/`**: Bootstrapping Helm charts and custom resource definitions:
    *   `argocd`: Argo CD Helm values and config.
    *   `karpenter`: Karpenter NodePool and EC2NodeClass manifests.
    *   `monitoring`: Prometheus and Grafana service and deployment specifications.
*   **`03-workloads/`**: Verification workloads (CUDA matrix validation and CPU test deployments).
*   **`docs/`**: Production operations, architecture documents, troubleshooting guides, hands-on lab guides (inside `labs/`), lessons learned engineering journal, and conceptual interview notes (inside `interview-notes/`).

---

## 2. Core Guidelines for AI Agents

When modifying this codebase, agents must strictly follow these rules:

1.  **Maintain Documentation Integrity:** Keep all verbose explanatory comments inside the `.tf` files. The comments are designed to teach SRE and Platform concepts. Do not strip comments when refactoring.
2.  **Use Private Subnets for Compute:** All compute resources (EC2, EKS worker nodes, ECS tasks) must be placed in `module.network.private_subnet_ids` unless they explicitly require public internet ingress (like load balancers).
3.  **Spot Instances First:** All compute nodes (Managed Node Groups or Karpenter provisioned nodes) should default to **Spot Instances** (`capacity_type = "SPOT"`) to minimize development costs.
4.  **No Hardcoded Credentials:** Never write static AWS keys (`AWS_ACCESS_KEY_ID`, etc.) or passwords in Terraform or Kubernetes manifests. Use EKS Pod Identity or KMS Envelope Encryption for secrets.
5.  **Always Validate Changes:** After any modification, run `terraform fmt` and `terraform validate`. If modifying Kubernetes manifests, run dry-run validation if a cluster is available.

---

## 3. Common Commands

*   **Initialize Terraform**: `terraform init`
    *   Downloads the AWS provider plugin and sets up the backend.
*   **Format code**: `terraform fmt`
    *   Ensures consistent formatting across all `.tf` files.
*   **Validate configuration**: `terraform validate`
    *   Checks for syntactic validity and internal consistency.
*   **Show execution plan**: `terraform plan`
    *   Displays what Terraform will do to reach the desired state.
*   **Apply changes**: `terraform apply` or `make apply`
    *   Executes the plan to create/update infrastructure.
*   **Destroy infrastructure**: `terraform destroy` or `make destroy`
    *   Removes all managed resources.
*   **View current state**: `terraform show`
    *   Displays the current state or a saved plan.
*   **Target specific resources**: `terraform apply -target=resource_type.name`
    *   Apply changes to only a subset of resources (use cautiously).

---

## 4. Typical Workflow

1. Run `terraform init` to prepare the working directory.
2. Run `terraform plan` to review changes.
3. Apply changes with `terraform apply` or `make apply`.
4. To clean up, run `terraform destroy` or `make destroy`.
