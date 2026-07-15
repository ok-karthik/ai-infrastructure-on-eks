# ==============================================================================
# Argo CD Bootstrapping via Helm
# ==============================================================================
# Why it's needed: Deploys Argo CD, a declarative GitOps continuous delivery tool.
# Once installed, Argo CD acts as the EKS cluster controller that watches a Git repository
# (containing Kubernetes manifests) and automatically synchronizes the cluster state
# to match the Git declaration. This is the industry-standard way to manage deployments
# in production.
#
# What happens without it: You must manually deploy apps using 'kubectl apply' or run
# commands from your CI/CD pipelines (e.g. GitHub Actions). This is a security risk
# (requires exposing EKS admin credentials to external systems), lacks automatic drift
# detection (if someone manually edits a pod, it won't be corrected), and makes disaster
# recovery slow and manual.
resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "7.7.0" # Pins the Argo CD chart version to ensure repeatable deployments
  namespace  = "argocd"

  # Why it's needed: Instructs Helm to create the namespace 'argocd' if it doesn't exist.
  # What happens without it: The deployment will fail immediately with a "namespace not found" error.
  create_namespace = true
  wait             = false


  # Configure Argo CD Core mode by disabling unnecessary components and scaling replicas to 0
  set {
    name  = "server.replicas"
    value = "0"
  }

  set {
    name  = "applicationSet.replicas"
    value = "0"
  }

  set {
    name  = "dex.enabled"
    value = "false"
  }

  set {
    name  = "notifications.enabled"
    value = "false"
  }

  set {
    name  = "redis.enabled"
    value = "true"
  }
}


# ==============================================================================
# Karpenter CRDs Installation
# ==============================================================================
# Why it's needed: Installs the Custom Resource Definitions (CRDs) for Karpenter
# (e.g. NodePool, EC2NodeClass). Karpenter requires these API schemas to be registered
# in Kubernetes before the controller starts.
resource "helm_release" "karpenter_crd" {
  name             = "karpenter-crd"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter-crd"
  version          = "1.13.0" # Keeps version in sync with the controller
  namespace        = "karpenter"
  create_namespace = true
}

# ==============================================================================
# Karpenter Controller Installation
# ==============================================================================
# Why it's needed: Installs the Karpenter autoscaling controller itself.
# It automatically maps to the IAM Role we associated via EKS Pod Identity.
resource "helm_release" "karpenter" {
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = "1.13.0"
  namespace        = "karpenter"
  create_namespace = true
  wait             = false # Prevents Terraform from timing out if pods take time to schedule


  # Karpenter needs the cluster name and endpoint to register nodes properly
  set {
    name  = "settings.clusterName"
    value = var.cluster_name
  }

  set {
    name  = "settings.clusterEndpoint"
    value = var.cluster_endpoint
  }

  set {
    name  = "replicas"
    value = var.karpenter_replicas
  }


  # Override post-install hook image to alpine/k8s to ensure /bin/sh is available and avoid ECR Public auth issues
  set {
    name  = "postInstallHook.image.repository"
    value = "docker.io/alpine/k8s"
  }

  set {
    name  = "postInstallHook.image.tag"
    value = "1.30.2"
  }

  set {
    name  = "postInstallHook.image.digest"
    value = ""
  }

  # Explicitly wait for CRDs to be registered before booting the controller
  depends_on = [
    helm_release.karpenter_crd
  ]
}

# ==============================================================================
# Karpenter Cleanup & Finalizer Removal
# ==============================================================================
# Why it's needed: When destroying Karpenter, Karpenter's custom resources (e.g. EC2NodeClass, NodePool)
# may have finalizers (like 'karpenter.k8s.aws/termination'). If the Karpenter controller is
# destroyed before these CRs, they will hang indefinitely during deletion because no controller
# runs to remove the finalizer. This resource runs a cleanup script during destroy to gracefully
# delete Karpenter resources first, and then forcefully strip finalizers from any remaining
# Karpenter resources to prevent the CRD uninstall from hanging.
resource "terraform_data" "karpenter_cleanup" {
  input = "${var.cluster_name}/${var.aws_region}"

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      echo "=== Starting Karpenter Resource Cleanup ==="
      CLUSTER_NAME=$(echo "${self.output}" | cut -d'/' -f1)
      AWS_REGION=$(echo "${self.output}" | cut -d'/' -f2)
      
      echo "Updating kubeconfig for cluster $CLUSTER_NAME in region $AWS_REGION..."
      aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" || true
      
      echo "Attempting to delete Karpenter resources..."
      kubectl delete ec2nodeclasses,nodepools,nodeclaims --all --timeout=15s || true
      
      echo "Checking and stripping remaining Karpenter finalizers..."
      for kind in ec2nodeclasses nodepools nodeclaims; do
        resources=$(kubectl get $kind -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
        for r in $resources; do
          echo "Patching finalizers on $kind/$r"
          kubectl patch $kind $r -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
        done
      done
      echo "=== Karpenter Resource Cleanup Complete ==="
    EOT
  }

  depends_on = [
    helm_release.karpenter
  ]
}

# ==============================================================================
# Apply Platform GitOps Manifests
# ==============================================================================
# Why it's needed: Automatically applies Karpenter NodePool and EC2NodeClass custom
# resources once Karpenter is deployed. This automates the compute provisioning
# configuration without requiring manual kubectl commands.
resource "terraform_data" "apply_gitops" {
  input = "${var.cluster_name}/${var.aws_region}"

  provisioner "local-exec" {
    command = <<-EOT
      echo "=== Applying Platform Configurations ==="
      aws eks update-kubeconfig --name "${var.cluster_name}" --region "${var.aws_region}"
      
      echo "Waiting for Karpenter deployment to be ready..."
      kubectl rollout status deployment/karpenter -n karpenter --timeout=90s
      
      echo "Applying Karpenter configurations..."
      kubectl apply -f ${path.module}/karpenter/
      
      echo "Applying monitoring configurations..."
      kubectl apply -f ${path.module}/monitoring/
      echo "=== Platform Configurations Applied ==="
    EOT
  }

  depends_on = [
    helm_release.karpenter
  ]
}
