# ==============================================================================
# Argo CD Bootstrapping via Helm
# ==============================================================================
# Why it's needed: Argo CD is the GitOps continuous delivery controller. It watches
# a Git repository containing Kubernetes manifests and reconciles the cluster to
# match, giving you drift detection and an auditable deploy history.
#
# What happens without it: you deploy with 'kubectl apply' from a laptop or a CI
# runner, which means exposing cluster admin credentials to CI, no drift detection,
# and a manual disaster-recovery path.
resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version
  namespace  = "argocd"

  create_namespace = true

  # wait = false: the release is considered applied once the API objects are
  # created rather than once every pod is Ready. On a one-node dev cluster the
  # Argo CD pods can sit Pending while Karpenter provisions capacity, and blocking
  # the apply on that just produces a Terraform timeout.
  wait = false

  # Trimmed to a controller-only install to fit a single t3.small system node.
  # This is a cost decision, not a recommendation: server.replicas = 0 means there
  # is no Argo CD API or web UI, so `argocd` CLI login and the dashboard are
  # unavailable. Scale server.replicas to 1 (and re-enable dex if you want SSO)
  # when you want the full experience.
  values = [yamlencode({
    server = {
      replicas = var.argocd_enable_server ? 1 : 0
    }
    applicationSet = {
      replicas = 0
    }
    dex = {
      enabled = false
    }
    notifications = {
      enabled = false
    }
    redis = {
      enabled = true
    }
  })]
}

# ==============================================================================
# Karpenter CRDs
# ==============================================================================
# Why it's needed: Installs the NodePool / EC2NodeClass / NodeClaim CRDs. These are
# shipped as a separate chart so that CRD upgrades can be sequenced independently
# of the controller, and so Helm does not try to garbage-collect CRDs on uninstall.
resource "helm_release" "karpenter_crd" {
  name             = "karpenter-crd"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter-crd"
  version          = var.karpenter_version
  namespace        = "karpenter"
  create_namespace = true
}

# ==============================================================================
# Karpenter Controller
# ==============================================================================
# Why it's needed: Karpenter watches for unschedulable pods and provisions
# right-sized EC2 capacity for them directly, without a per-instance-type Auto
# Scaling Group. This is what makes on-demand GPU node provisioning possible.
#
# Authentication: the controller's ServiceAccount is bound to an IAM role through
# the EKS Pod Identity association created in 01-infrastructure/02-eks/karpenter.tf.
# No IRSA annotation or static credentials are needed here.
resource "helm_release" "karpenter" {
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = var.karpenter_version
  namespace        = "karpenter"
  create_namespace = true
  wait             = false

  values = [yamlencode({
    replicas = var.karpenter_replicas

    settings = {
      clusterName     = var.cluster_name
      clusterEndpoint = var.cluster_endpoint
    }
  })]

  # CRDs must be registered before the controller starts, or its informers fail
  # to establish watches and the pod crash-loops.
  depends_on = [
    helm_release.karpenter_crd
  ]
}

# ==============================================================================
# NVIDIA GPU Operator
# ==============================================================================
# Why it's needed: A GPU is not usable by Kubernetes just because the instance has
# one. Something has to load the kernel driver, wire the NVIDIA container runtime
# into containerd, and run a device plugin that advertises nvidia.com/gpu to the
# kubelet. The GPU Operator manages that whole stack as a set of DaemonSets driven
# by a ClusterPolicy CR.
#
# What happens without it: GPU nodes join the cluster and report zero
# nvidia.com/gpu capacity, so GPU pods stay Pending forever, and Karpenter keeps
# launching more GPU nodes trying to satisfy them.
resource "helm_release" "gpu_operator" {
  count = var.install_gpu_operator ? 1 : 0

  name             = "gpu-operator"
  repository       = "https://helm.ngc.nvidia.com/nvidia"
  chart            = "gpu-operator"
  version          = var.gpu_operator_version
  namespace        = "gpu-operator"
  create_namespace = true
  wait             = false

  # The GPU Operator install takes several minutes on a fresh node because the
  # operand images are large.
  timeout = 900

  values = [yamlencode({
    # driver.enabled = false and toolkit.enabled = false are deliberate.
    #
    # The GPU NodePool (02-platform/karpenter/karpenter-gpu-nodeclass.yaml) selects
    # the EKS NVIDIA-optimized AL2023 AMI, which already ships the NVIDIA kernel
    # driver and the container toolkit pre-installed and pre-configured. Letting
    # the operator also install them means two owners for the same kernel module
    # and containerd config: the driver DaemonSet fails to load a module that is
    # already resident, and the toolkit container rewrites the runtime config the
    # AMI already set up. Symptom is a driver pod stuck in Init/CrashLoopBackOff
    # while nvidia-smi works fine on the host.
    #
    # Set var.gpu_driver_managed_by_operator = true if you switch the NodeClass to
    # a plain AL2023 AMI, where the operator does need to install both.
    driver = {
      enabled = var.gpu_driver_managed_by_operator
    }
    toolkit = {
      enabled = var.gpu_driver_managed_by_operator
    }

    # Node Feature Discovery labels nodes with their PCI devices. The operator's
    # operand DaemonSets use those labels (feature.node.kubernetes.io/pci-10de.present)
    # to schedule only onto nodes that actually have an NVIDIA card.
    nfd = {
      enabled = true
    }

    # DCGM Exporter publishes GPU telemetry on :9400 for Prometheus to scrape.
    dcgmExporter = {
      enabled = true
    }

    # ----------------------------------------------------------------------
    # GPU Time Slicing
    # ----------------------------------------------------------------------
    # Presents one physical GPU to the scheduler as N schedulable units, letting
    # several small pods share a card instead of each holding an entire GPU.
    #
    # This is configured through the chart rather than as a separate ConfigMap +
    # `kubectl patch clusterpolicy` on purpose: the device plugin reads this
    # ConfigMap at startup, so a manually-applied ConfigMap has to exist before the
    # DaemonSet rolls out or the plugin starts with no sharing config. Letting the
    # chart own both removes that ordering race and keeps one source of truth.
    #
    # IMPORTANT: time slicing multiplexes COMPUTE only. All replicas share the
    # card's VRAM with no isolation and no per-pod memory limit, so one pod
    # allocating too much triggers CUDA OOM in its neighbours. Use MIG (A100/H100)
    # when you need hard memory isolation. See docs/labs/04-time-slicing.md.
    devicePlugin = {
      config = {
        create  = true
        name    = "device-plugin-config"
        default = "time-sliced"
        data = {
          "time-sliced" = yamlencode({
            version = "v1"
            sharing = {
              timeSlicing = {
                resources = [
                  {
                    name     = "nvidia.com/gpu"
                    replicas = var.gpu_time_slicing_replicas
                  }
                ]
              }
            }
          })

          # Kept alongside so you can flip a node back to exclusive access with
          # `kubectl label node <n> nvidia.com/device-plugin.config=exclusive`
          # without editing the ConfigMap.
          "exclusive" = yamlencode({
            version = "v1"
            flags = {
              migStrategy = "none"
            }
          })
        }
      }
    }
  })]

  # Karpenter must exist first: the GPU Operator's operands only become Ready once
  # a GPU node exists, and only Karpenter can provision one.
  depends_on = [
    helm_release.karpenter
  ]
}

# ==============================================================================
# Karpenter Cleanup & Finalizer Removal
# ==============================================================================
# Why it's needed: Karpenter's custom resources carry finalizers. If the controller
# is destroyed before its CRs, deletion hangs forever because nothing is left
# running to remove the finalizer, and `terraform destroy` blocks indefinitely on
# the CRD uninstall. This runs on destroy to delete the CRs gracefully first, then
# force-strips any finalizers that remain.
resource "terraform_data" "karpenter_cleanup" {
  # Captured into the resource itself because destroy-time provisioners may not
  # reference variables or other resources.
  input = {
    cluster_name = var.cluster_name
    aws_region   = var.aws_region
  }

  provisioner "local-exec" {
    when        = destroy
    command     = <<-EOT
      set -u
      echo "=== Starting Karpenter Resource Cleanup ==="

      echo "Updating kubeconfig for cluster ${self.input.cluster_name} in ${self.input.aws_region}..."
      aws eks update-kubeconfig --name "${self.input.cluster_name}" --region "${self.input.aws_region}" || true

      echo "Attempting graceful deletion of Karpenter resources..."
      kubectl delete nodeclaims --all --timeout=120s || true
      kubectl delete nodepools --all --timeout=60s || true
      kubectl delete ec2nodeclasses --all --timeout=60s || true

      echo "Stripping any remaining Karpenter finalizers..."
      for kind in nodeclaims nodepools ec2nodeclasses; do
        for r in $(kubectl get "$kind" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
          echo "Patching finalizers on $kind/$r"
          kubectl patch "$kind" "$r" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
        done
      done
      echo "=== Karpenter Resource Cleanup Complete ==="
    EOT
    interpreter = ["/bin/bash", "-c"]
  }

  depends_on = [
    helm_release.karpenter
  ]
}

# ==============================================================================
# Apply Karpenter NodePools / NodeClasses and the Monitoring Stack
# ==============================================================================
# Why it's needed: Karpenter provisions nothing until a NodePool and EC2NodeClass
# exist. These stay as plain YAML rather than Terraform resources so that Argo CD
# can take ownership of the same files later (see 03-workloads/argocd-app.yaml)
# without a rewrite.
#
# triggers_replace re-runs this whenever a manifest changes, so editing a NodePool
# is picked up by `terraform apply` instead of silently doing nothing.
resource "terraform_data" "apply_gitops" {
  triggers_replace = {
    cluster_name = var.cluster_name
    aws_region   = var.aws_region
    karpenter_manifests = sha1(join("", [
      for f in sort(fileset("${path.module}/karpenter", "*.yaml")) :
      filesha1("${path.module}/karpenter/${f}")
    ]))
    monitoring_manifests = sha1(join("", [
      for f in sort(fileset("${path.module}/monitoring", "*.yaml")) :
      filesha1("${path.module}/monitoring/${f}")
    ]))
  }

  provisioner "local-exec" {
    command     = <<-EOT
      set -euo pipefail
      echo "=== Applying Platform Configurations ==="
      aws eks update-kubeconfig --name "${var.cluster_name}" --region "${var.aws_region}"

      echo "Waiting for the Karpenter controller to become available..."
      kubectl rollout status deployment/karpenter -n karpenter --timeout=300s

      echo "Applying Karpenter NodePools and EC2NodeClasses..."
      kubectl apply -f "${path.module}/karpenter/"

      echo "Applying the monitoring stack..."
      kubectl apply -f "${path.module}/monitoring/"
      echo "=== Platform Configurations Applied ==="
    EOT
    interpreter = ["/bin/bash", "-c"]
  }

  depends_on = [
    helm_release.karpenter
  ]
}
