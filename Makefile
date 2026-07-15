# ==============================================================================
# Makefile for AI Infrastructure Platform on Amazon EKS
# ==============================================================================
# Automates Terraform execution, manages Kubernetes configurations, and coordinates
# multi-layer GPU infrastructure deployment.

.PHONY: all init fmt validate plan apply apply-all destroy destroy-all help

SHELL := /bin/bash

# Configuration
PARALLELISM ?= 30

# Default target
all: help

help:
	@echo "Available commands:"
	@echo "  make init          - Run terraform init inside the infrastructure module"
	@echo "  make fmt           - Format all terraform configurations recursively"
	@echo "  make validate      - Validate all terraform syntax"
	@echo "  make plan          - Show infrastructure execution plan"
	@echo "  make apply         - Run infrastructure apply and auto-deploy configurations"
	@echo "  make apply-all     - Run progressive module-by-module apply (Network -> EKS -> Platform)"
	@echo "  make destroy       - Teardown all resources and clean up configurations"
	@echo "  make destroy-all   - Progressive teardown of modules in reverse order"

init:
	@echo "=== Initializing Terraform ==="
	terraform -chdir=01-infrastructure init

fmt:
	@echo "=== Formatting Terraform Code ==="
	terraform -chdir=01-infrastructure fmt -recursive
	terraform -chdir=02-platform fmt -recursive

validate:
	@echo "=== Validating Terraform Code ==="
	terraform -chdir=01-infrastructure validate

plan:
	@echo "=== Planning Terraform Changes ==="
	terraform -chdir=01-infrastructure plan -parallelism=$(PARALLELISM)

apply:
	@echo "==========================================="
	@echo "Starting Infrastructure & Platform Apply..."
	@echo "==========================================="
	@start=$$(date +%s); \
	terraform -chdir=01-infrastructure apply -parallelism=$(PARALLELISM) -auto-approve; \
	status=$$?; \
	end=$$(date +%s); \
	elapsed=$$((end - start)); \
	min=$$((elapsed / 60)); \
	sec=$$((elapsed % 60)); \
	echo "-------------------------------------------"; \
	if [ $$status -eq 0 ]; then \
		echo "Apply Succeeded!"; \
		aws eks update-kubeconfig --region us-east-1 --name dev-eks-cluster; \
		echo "Applying Karpenter and Monitoring configurations..."; \
		kubectl apply -f 02-platform/karpenter/; \
		kubectl apply -f 02-platform/monitoring/; \
	else \
		echo "Apply Failed!"; \
	fi; \
	echo "Total Time: $${min}m $${sec}s ($${elapsed} seconds)"; \
	echo "==========================================="; \
	exit $$status

apply-all:
	@echo "==========================================="
	@echo "Starting Progressive Module-by-Module Apply..."
	@echo "==========================================="
	@echo
	@# 1. Network Module
	@start=$$(date +%s); \
	echo "--> Applying Network Module (VPC, Subnets)..."; \
	terraform -chdir=01-infrastructure apply -target=module.network -parallelism=$(PARALLELISM) -auto-approve; \
	status=$$?; \
	end=$$(date +%s); \
	net_time=$$((end - start)); \
	if [ $$status -ne 0 ]; then echo "Error: Network Apply failed!"; exit 1; fi; \
	echo "Network Module Apply Finished in $${net_time}s"; \
	echo "-------------------------------------------"; \
	echo; \
	\
	# 2. EKS Compute Module; \
	start=$$(date +%s); \
	echo "--> Applying EKS Module (Cluster, Managed Node Group)..."; \
	terraform -chdir=01-infrastructure apply -target=module.eks -parallelism=$(PARALLELISM) -auto-approve; \
	status=$$?; \
	end=$$(date +%s); \
	eks_time=$$((end - start)); \
	if [ $$status -ne 0 ]; then echo "Error: EKS Apply failed!"; exit 1; fi; \
	echo "EKS Module Apply Finished in $${eks_time}s"; \
	echo "-------------------------------------------"; \
	echo; \
	\
	# 3. Platform Bootstrap Module; \
	start=$$(date +%s); \
	echo "--> Applying Platform Bootstrap Module (Argo CD, Karpenter)..."; \
	terraform -chdir=01-infrastructure apply -target=module.bootstrap -parallelism=$(PARALLELISM) -auto-approve; \
	status=$$?; \
	end=$$(date +%s); \
	boot_time=$$((end - start)); \
	if [ $$status -ne 0 ]; then echo "Error: Bootstrap Apply failed!"; exit 1; fi; \
	echo "Platform Bootstrap Module Apply Finished in $${boot_time}s"; \
	echo "-------------------------------------------"; \
	echo; \
	\
	# Final summary; \
	total=$$((net_time + eks_time + boot_time)); \
	t_min=$$((total / 60)); \
	t_sec=$$((total % 60)); \
	echo "==========================================="; \
	echo "Terraform Module Apply Summary:"; \
	echo "  1. Network Module:    $${net_time}s"; \
	echo "  2. EKS Module:        $${eks_time}s"; \
	echo "  3. Bootstrap Module:  $${boot_time}s"; \
	echo "-------------------------------------------"; \
	echo "Total Duration:         $${t_min}m $${t_sec}s ($${total} seconds)"; \
	echo "==========================================="

destroy:
	@echo "==========================================="
	@echo "Starting Standard Infrastructure Teardown..."
	@echo "==========================================="
	@start=$$(date +%s); \
	aws eks update-kubeconfig --region us-east-1 --name dev-eks-cluster || true; \
	echo "Deleting Kubernetes Configurations..."; \
	kubectl delete -f 02-platform/karpenter/ || true; \
	kubectl delete -f 02-platform/monitoring/ || true; \
	terraform -chdir=01-infrastructure destroy -parallelism=$(PARALLELISM) -auto-approve; \
	status=$$?; \
	end=$$(date +%s); \
	elapsed=$$((end - start)); \
	min=$$((elapsed / 60)); \
	sec=$$((elapsed % 60)); \
	echo "-------------------------------------------"; \
	if [ $$status -eq 0 ]; then \
		echo "Destroy Succeeded!"; \
	else \
		echo "Destroy Failed!"; \
	fi; \
	echo "Total Time: $${min}m $${sec}s ($${elapsed} seconds)"; \
	echo "==========================================="; \
	exit $$status

destroy-all:
	@echo "==========================================="
	@echo "Starting Progressive Module-by-Module Destroy..."
	@echo "==========================================="
	@echo
	@# 1. Platform Bootstrap Module
	@start=$$(date +%s); \
	echo "--> Destroying Platform Bootstrap Module (Argo CD, Karpenter)..."; \
	terraform -chdir=01-infrastructure destroy -target=module.bootstrap -parallelism=$(PARALLELISM) -auto-approve; \
	status=$$?; \
	end=$$(date +%s); \
	boot_time=$$((end - start)); \
	echo "Bootstrap Module Destroy Finished in $${boot_time}s"; \
	echo "-------------------------------------------"; \
	echo; \
	\
	# 2. EKS Module; \
	start=$$(date +%s); \
	echo "--> Destroying EKS Module (Cluster, Node Group)..."; \
	terraform -chdir=01-infrastructure destroy -target=module.eks -parallelism=$(PARALLELISM) -auto-approve; \
	status=$$?; \
	end=$$(date +%s); \
	eks_time=$$((end - start)); \
	echo "EKS Module Destroy Finished in $${eks_time}s"; \
	echo "-------------------------------------------"; \
	echo; \
	\
	# 3. Network Module; \
	start=$$(date +%s); \
	echo "--> Destroying Network Module (VPC, Subnets)..."; \
	terraform -chdir=01-infrastructure destroy -target=module.network -parallelism=$(PARALLELISM) -auto-approve; \
	status=$$?; \
	end=$$(date +%s); \
	net_time=$$((end - start)); \
	echo "Network Module Destroy Finished in $${net_time}s"; \
	echo "-------------------------------------------"; \
	echo; \
	\
	# Final summary; \
	total=$$((net_time + eks_time + boot_time)); \
	t_min=$$((total / 60)); \
	t_sec=$$((total % 60)); \
	echo "==========================================="; \
	echo "Terraform Module Destroy Summary:"; \
	echo "  1. Bootstrap Module:  $${boot_time}s"; \
	echo "  2. EKS Module:        $${eks_time}s"; \
	echo "  3. Network Module:    $${net_time}s"; \
	echo "-------------------------------------------"; \
	echo "Total Duration:         $${t_min}m $${t_sec}s ($${total} seconds)"; \
	echo "==========================================="
