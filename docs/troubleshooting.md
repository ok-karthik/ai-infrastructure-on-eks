# Production Troubleshooting & Failure Modes Runbook

This runbook catalogs operational issues, diagnostic workflows, and resolutions encountered when operating the AI Infrastructure Platform on Amazon EKS.

---

## 1. Karpenter Launches Unexpected GPU Node

### Symptoms
*   Karpenter provisions a GPU instance (e.g. `g4dn.xlarge`) for CPU-only workloads.

### Diagnostic Steps

*   **Purpose:** Inspect Karpenter logs to identify the scheduling decision trigger.
    *   **Command:**
        ```bash
        kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --tail=100
        ```
    *   **Expected Result:** Logs indicating dynamic scale-up and target nodeclaim triggers.
    *   **Validation:** Verify if a specific pod request matched the GPU NodePool rules.

*   **Purpose:** Inspect the pending pod's resource requests, selectors, and tolerations.
    *   **Command:**
        ```bash
        kubectl get pod <pod-name> -o yaml
        ```
    *   **Expected Result:** Pod specification containing tolerations or resource requests.
    *   **Validation:** Check if `tolerations` contains a wildcard or tolerates the GPU taint without a selector.

### Root Cause
*   **Missing Node Selector:** The pod tolerated the GPU taint (`nvidia.com/gpu:NoSchedule`) but lacked a node selector (`accelerator: nvidia-gpu`), allowing Karpenter to assign it to GPU nodes.
*   **Missing Taint Isolation:** The Karpenter `NodePool` lacked a `taints` block, allowing standard CPU workloads to schedule on GPU compute.

### Resolution
*   Add a strict taint block to the GPU `NodePool`:
    ```yaml
    spec:
      template:
        spec:
          taints:
            - key: nvidia.com/gpu
              value: "true"
              effect: NoSchedule
    ```
*   Force GPU workloads to declare both a selector and toleration:
    ```yaml
    spec:
      tolerations:
        - key: "nvidia.com/gpu"
          operator: "Exists"
          effect: "NoSchedule"
      nodeSelector:
        accelerator: nvidia-gpu
    ```

### Lessons Learned
*   Enforce taints on all expensive compute pools.
*   Validate pod specifications using admission controllers (e.g. Gatekeeper or Kyverno) to prevent incorrect scheduling.

---

## 2. Kubernetes Device Plugin CrashLoopBackOff

### Symptoms
*   `nvidia-device-plugin-daemonset` pods enter `CrashLoopBackOff` status.

### Diagnostic Steps

*   **Purpose:** Inspect container crash logs.
    *   **Command:**
        ```bash
        kubectl logs -n gpu-operator -l app=nvidia-device-plugin-daemonset --tail=50
        ```
    *   **Expected Result:** Logs indicating gRPC socket connection failures or empty device listings.
    *   **Validation:** Verify if the driver character files exist on the host filesystem.

*   **Purpose:** Verify if the host drivers are loaded and accessible.
    *   **Command:**
        ```bash
        kubectl exec -n gpu-operator ds/nvidia-device-plugin-daemonset -- nvidia-smi
        ```
    *   **Note:** Many guides use `ds/nvidia-driver-daemonset` here. That DaemonSet does not exist in this cluster, because the driver ships in the EKS NVIDIA-optimized AMI and the operator runs with `driver.enabled=false`. See [Lab 02](labs/02-gpu-operator.md).
    *   **Expected Result:** Hardware status report from the driver module.
    *   **Validation:** Verify that `/dev/nvidiactl` and `/dev/nvidia0` are present on the host.

### Root Cause
*   **Module Load Race Condition:** The Kubernetes Device Plugin booted before the driver compiled or loaded the host kernel module.
*   **Socket Write Access Denied:** Host security policies blocked Kubelet UNIX socket access (`/var/lib/kubelet/device-plugins/kubelet.sock`).

### Resolution
*   Inject an initContainer to wait for host driver files:
    ```yaml
    initContainers:
      - name: wait-for-driver
        image: busybox:1.36
        command: ['sh', '-c', 'until [ -e /dev/nvidiactl ]; do sleep 5; done']
    ```

### Lessons Learned
*   Guard down-stream daemonset boots with initialization checks.
*   For details on Kubelet socket endpoints, see the [Kubernetes Device Plugin Guide](interview-notes/device-plugin.md).

---

## 3. Pods Stuck in Pending (GPU Not Advertised)

### Symptoms
*   Pods requesting `nvidia.com/gpu` remain `Pending`.
*   Events show `Insufficient nvidia.com/gpu`.

### Diagnostic Steps

*   **Purpose:** Check node allocatable resource capacities.
    *   **Command:**
        ```bash
        kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU_ALLOCATABLE:.status.allocatable."nvidia\.com/gpu"
        ```
    *   **Expected Result:** Nodes and their corresponding allocatable GPU counts.
    *   **Validation:** Verify if the capacity value is `0` or blank.

*   **Purpose:** Inspect Node Feature Discovery labels on the node.
    *   **Command:**
        ```bash
        kubectl get nodes --show-labels | grep nvidia
        ```
    *   **Expected Result:** Node labels indicating hardware presence (e.g. `pci-10de.present`).
    *   **Validation:** Verify that NFD successfully labeled the node.

### Root Cause
*   **NFD Labeling Failure:** Node Feature Discovery failed to label the node, causing the GPU Operator to bypass daemon deployment.
*   **Runtime Class Mismatch:** The Container Toolkit failed to register containerd configuration lines, blocking Kubelet's hardware mappings.

### Resolution
*   Restart NFD daemonsets to force a node scan:
    ```bash
    kubectl rollout restart daemonset -n gpu-operator node-feature-discovery
    ```
*   Confirm the runtime config block in containerd `/etc/containerd/config.toml` matches:
    ```toml
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia]
      runtime_type = "io.containerd.runc.v2"
    ```

### Lessons Learned
*   Kubelet will not advertise GPU capacity until the device plugin completes registration.
*   Monitor cluster metrics for allocatable capacity drift.

---

## 4. GPU Operator Stuck in Reconciling

### Symptoms
*   `ClusterPolicy` custom resource state remains in `Reconciling` or `InProgress`.

### Diagnostic Steps

*   **Purpose:** Inspect ClusterPolicy reconciliation events.
    *   **Command:**
        ```bash
        kubectl describe clusterpolicy default
        ```
    *   **Expected Result:** Detailed status block and event records.
    *   **Validation:** Check for compilation or container image pull failures.

> [!NOTE]
> **This failure mode does not occur in this cluster's default configuration.**
> It applies when the GPU Operator manages the driver
> (`gpu_driver_managed_by_operator = true`, or any plain AL2023/Ubuntu AMI).
> Here the driver comes from the EKS NVIDIA-optimized AMI and there is no
> compile step to fail. It is documented because it is the most common GPU
> Operator failure in the wild, and because choosing the pre-installed path is
> precisely how it was avoided.

*   **Purpose:** Retrieve driver build container compiler logs (operator-managed driver only).
    *   **Command:**
        ```bash
        kubectl logs -n gpu-operator -l app=nvidia-driver-daemonset -c nvidia-driver --tail=100
        ```
    *   **Expected Result:** GCC compilation logs.
    *   **Validation:** Check for compiler errors or missing kernel header packages.

### Root Cause
*   **Kernel Version Drift:** The host kernel is newer than any driver version the image can build against.
*   **Missing Kernel Headers:** The compile container cannot fetch headers matching the running kernel.
*   **Internet Egress Blockage:** Compile containers in private subnets could not reach upstream package repositories.

### Resolution
*   Use a pre-baked GPU AMI (the EKS-optimized AL2023 NVIDIA AMI) and disable the operator's driver and toolkit operands. This is what this repository does — see `02-platform/main.tf`.
*   If you must compile dynamically, pin the NodePool to AMIs whose kernel is covered by the driver support matrix.
*   *For operand configuration, see the [GPU Operator Guide](interview-notes/gpu-operator.md) and [Lab 02](labs/02-gpu-operator.md).*

### Lessons Learned
*   Dynamic driver compilation puts kernel-header availability and internet egress on the node bootstrap path. Pre-baked driver AMIs remove both dependencies and shorten scale-up.

---

## 5. GPU Time Slicing Doesn't Partition Resources

### Symptoms
*   Physical node only advertises `1` GPU instead of the configured virtual slices (e.g. `4`).

### Diagnostic Steps

*   **Purpose:** Check the applied sharing ConfigMap contents.
    *   **Command:**
        ```bash
        kubectl get configmap -n gpu-operator device-plugin-config -o yaml
        ```
    *   **Expected Result:** YAML block detailing replicas and configurations.
    *   **Validation:** Ensure keys match the official schema.

*   **Purpose:** Check ClusterPolicy config references.
    *   **Command:**
        ```bash
        kubectl get clusterpolicy default -o jsonpath='{.spec.devicePlugin.config}'
        ```
    *   **Expected Result:** Policy config mapping targets.
    *   **Validation:** Ensure the default selector matches the ConfigMap key.

### Root Cause
*   **Malformed Configuration:** The ConfigMap data block lacked the `resources` array or used incorrect keys.
*   **Namespace Mismatch:** The ConfigMap was created in `default` rather than the `gpu-operator` namespace.
*   **Key Mismatch:** `spec.devicePlugin.config.default` names a key that does not exist in the ConfigMap. The plugin then fails to start and GPU capacity disappears from the node entirely.
*   **Ordering Race:** The ConfigMap was applied *after* the device plugin DaemonSet rolled out. The plugin reads it at startup, so it came up with no sharing config and advertised `1`.

### Resolution

In this repository time slicing is **owned by Terraform**, not by a hand-applied
ConfigMap. The GPU Operator Helm release creates the ConfigMap and points the
`ClusterPolicy` at it in one step, which is what removes the ordering race above.

Change the slice count with a variable and re-apply:

```bash
terraform -chdir=01-infrastructure apply -var 'gpu_time_slicing_replicas=8'
```

To repair drift after someone patched the `ClusterPolicy` by hand:

```bash
terraform -chdir=01-infrastructure apply -target=module.bootstrap
```

The generated ConfigMap, for reference:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: device-plugin-config
  namespace: gpu-operator
data:
  time-sliced: |-
    version: v1
    sharing:
      timeSlicing:
        resources:
          - name: nvidia.com/gpu
            replicas: 4
```

*   *See [Lab 04](labs/04-time-slicing.md) and the [Virtualization Models Guide](interview-notes/time-slicing.md).*

### Lessons Learned
*   Configuration that a controller reads **at startup** must be created by the same unit of deployment as the controller. Splitting them across `kubectl apply` and Helm introduces an ordering dependency that works on a slow cluster and fails on a fast one.

---

## Related Documentation
*   **System Layouts:** [Architecture Topology](architecture.md) | [Performance Profiling](performance.md) | [Future Roadmap](roadmap.md)
*   **Conceptual Focus:** [Device Plugin Interface](interview-notes/device-plugin.md) | [GPU Operator Internals](interview-notes/gpu-operator.md) | [Virtualization Models](interview-notes/time-slicing.md) | [Karpenter Scheduling](interview-notes/karpenter.md)
*   **Journal Logs:** [Post-Mortems & Lessons Learned](lessons-learned.md)
