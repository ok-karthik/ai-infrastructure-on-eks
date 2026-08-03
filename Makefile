# ==============================================================================
# Makefile for the AI Infrastructure Platform on Amazon EKS
# ==============================================================================
# Entrypoint for Terraform execution and cluster operations.
#
# Override any variable on the command line, e.g.:
#   make apply REGION=us-west-2 CLUSTER_NAME=my-cluster
#
# NOTE on recipe style: each step is its own target invoked through $(MAKE)
# rather than one long backslash-continued shell block. A `#` comment inside a
# continued block silently comments out every remaining line, which is exactly
# how the previous apply-all/destroy-all targets came to skip most of their work.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------
REGION       ?= us-east-1
CLUSTER_NAME ?= dev-eks-cluster
TF_DIR       ?= 01-infrastructure
PLATFORM_DIR ?= 02-platform
PARALLELISM  ?= 30

TF        := terraform -chdir=$(TF_DIR)
TF_APPLY  := $(TF) apply -parallelism=$(PARALLELISM) -auto-approve
TF_DESTROY := $(TF) destroy -parallelism=$(PARALLELISM) -auto-approve

.DEFAULT_GOAL := help

.PHONY: help init fmt fmt-check validate lint plan apply apply-all \
        destroy destroy-all kubeconfig status gpu-test gpu-clean \
        _apply-network _apply-eks _apply-bootstrap \
        _destroy-bootstrap _destroy-eks _destroy-network

# ------------------------------------------------------------------------------
# Help
# ------------------------------------------------------------------------------
help:
	@echo "AI Infrastructure Platform on EKS"
	@echo ""
	@echo "Setup & validation:"
	@echo "  make init          Initialize Terraform providers and modules"
	@echo "  make fmt           Format all Terraform files"
	@echo "  make fmt-check     Check formatting without writing (used by CI)"
	@echo "  make validate      Validate Terraform configuration"
	@echo "  make lint          Run tflint across all modules"
	@echo "  make plan          Show the execution plan"
	@echo ""
	@echo "Deploy:"
	@echo "  make apply         Apply everything in one pass"
	@echo "  make apply-all     Apply module by module (network -> eks -> platform)"
	@echo ""
	@echo "Operate:"
	@echo "  make kubeconfig    Point local kubectl at the cluster"
	@echo "  make status        Show nodes, GPU capacity, and platform pods"
	@echo "  make gpu-test      Deploy the CUDA load generator and watch provisioning"
	@echo "  make gpu-clean     Remove GPU test workloads (scales GPU nodes back down)"
	@echo ""
	@echo "Teardown:"
	@echo "  make destroy       Destroy everything"
	@echo "  make destroy-all   Destroy module by module (reverse order)"
	@echo ""
	@echo "Current config: REGION=$(REGION) CLUSTER_NAME=$(CLUSTER_NAME)"

# ------------------------------------------------------------------------------
# Setup & validation
# ------------------------------------------------------------------------------
init:
	@echo "==> Initializing Terraform"
	$(TF) init -input=false

fmt:
	@echo "==> Formatting Terraform"
	terraform -chdir=$(TF_DIR) fmt -recursive
	terraform -chdir=$(PLATFORM_DIR) fmt -recursive

fmt-check:
	@echo "==> Checking Terraform formatting"
	terraform -chdir=$(TF_DIR) fmt -recursive -check -diff
	terraform -chdir=$(PLATFORM_DIR) fmt -recursive -check -diff

validate:
	@echo "==> Validating Terraform"
	$(TF) validate

lint:
	@echo "==> Linting Terraform"
	@command -v tflint >/dev/null || { echo "tflint not installed: brew install tflint"; exit 1; }
	cd $(TF_DIR) && tflint --recursive

plan:
	@echo "==> Planning"
	$(TF) plan -parallelism=$(PARALLELISM)

# ------------------------------------------------------------------------------
# Deploy
# ------------------------------------------------------------------------------
apply:
	@echo "==> Applying infrastructure and platform"
	@start=$$(date +%s); \
	$(TF_APPLY); \
	end=$$(date +%s); \
	echo "==> Apply completed in $$(( (end - start) / 60 ))m $$(( (end - start) % 60 ))s"
	@$(MAKE) --no-print-directory kubeconfig
	@echo "==> Done. Run 'make status' to inspect the cluster."

# Module-by-module apply. Useful when debugging a failure, because a targeted
# apply keeps the blast radius small and makes it obvious which layer broke.
#
# -target is deliberate here and Terraform will warn about it; that warning is
# expected for this workflow and does not apply to `make apply`.
apply-all: _apply-network _apply-eks _apply-bootstrap
	@$(MAKE) --no-print-directory kubeconfig
	@echo "==> All modules applied."

_apply-network:
	@echo "==> [1/3] Network module (VPC, subnets, NAT)"
	$(TF_APPLY) -target=module.network

_apply-eks:
	@echo "==> [2/3] EKS module (control plane, node group, IAM)"
	$(TF_APPLY) -target=module.eks

_apply-bootstrap:
	@echo "==> [3/3] Platform module (Argo CD, Karpenter, GPU Operator)"
	$(TF_APPLY) -target=module.bootstrap

# ------------------------------------------------------------------------------
# Operate
# ------------------------------------------------------------------------------
kubeconfig:
	@echo "==> Updating kubeconfig for $(CLUSTER_NAME) in $(REGION)"
	aws eks update-kubeconfig --region $(REGION) --name $(CLUSTER_NAME)

status:
	@echo "==> Nodes"
	@kubectl get nodes -o wide
	@echo ""
	@echo "==> GPU capacity advertised to the scheduler"
	@kubectl get nodes -o custom-columns=NODE:.metadata.name,GPU_CAPACITY:.status.capacity.'nvidia\.com/gpu',GPU_ALLOCATABLE:.status.allocatable.'nvidia\.com/gpu'
	@echo ""
	@echo "==> Karpenter NodeClaims"
	@kubectl get nodeclaims 2>/dev/null || echo "(Karpenter CRDs not installed yet)"
	@echo ""
	@echo "==> GPU Operator pods"
	@kubectl get pods -n gpu-operator 2>/dev/null || echo "(gpu-operator namespace not present)"

# Deploys the CUDA load generator, which is unschedulable until Karpenter
# provisions a GPU node. Watching nodeclaims here is the actual demo.
gpu-test:
	@echo "==> Deploying the GPU load generator"
	kubectl apply -f 03-workloads/gpu-test-deployment.yaml
	@echo ""
	@echo "==> Watching Karpenter provision GPU capacity (Ctrl-C to stop)"
	@echo "    A g4dn.xlarge Spot node typically takes 60-90s to become Ready."
	kubectl get nodeclaims -w

gpu-clean:
	@echo "==> Removing GPU test workloads"
	kubectl delete -f 03-workloads/gpu-test-deployment.yaml --ignore-not-found
	@echo "==> Karpenter will consolidate the empty GPU node shortly (consolidateAfter: 1m)."

# ------------------------------------------------------------------------------
# Teardown
# ------------------------------------------------------------------------------
# GPU Spot instances are the most expensive thing here. Always confirm teardown
# actually finished; a failed destroy that leaves a NAT Gateway or a g4dn node
# running is the single most common way this project costs real money.
destroy:
	@echo "==> Destroying all resources"
	@start=$$(date +%s); \
	$(TF_DESTROY); \
	end=$$(date +%s); \
	echo "==> Destroy completed in $$(( (end - start) / 60 ))m $$(( (end - start) % 60 ))s"
	@echo ""
	@echo "==> Verify nothing is left running:"
	@echo "    aws ec2 describe-instances --region $(REGION) \\"
	@echo "      --filters Name=instance-state-name,Values=running \\"
	@echo "      --query 'Reservations[].Instances[].[InstanceId,InstanceType]' --output table"

destroy-all: _destroy-bootstrap _destroy-eks _destroy-network
	@echo "==> All modules destroyed."

_destroy-bootstrap:
	@echo "==> [1/3] Destroying platform module (Argo CD, Karpenter, GPU Operator)"
	$(TF_DESTROY) -target=module.bootstrap

_destroy-eks:
	@echo "==> [2/3] Destroying EKS module"
	$(TF_DESTROY) -target=module.eks

_destroy-network:
	@echo "==> [3/3] Destroying network module"
	$(TF_DESTROY) -target=module.network
