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
        kubectl exec -n gpu-operator ds/nvidia-driver-daemonset -- nvidia-smi
        ```
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

*   **Purpose:** Retrieve driver build container compiler logs.
    *   **Command:**
        ```bash
        kubectl logs -n gpu-operator -l app=nvidia-driver-daemonset -c nvidia-driver --tail=100
        ```
    *   **Expected Result:** GCC compiler compilation logs.
    *   **Validation:** Check for compiler syntax errors or missing package files.

### Root Cause
*   **Kernel Version Drift:** The host operating system kernel was newer than the pre-compiled driver image version.
*   **Internet Egress Blockage:** Compiler containers in private subnets failed to download external kernel headers.

### Resolution
*   Configure Karpenter to target specific AMIs matching the driver version support matrix.
*   Use pre-baked GPU AMIs (such as the EKS-optimized AL2023 GPU AMI) to bypass compile-time actions.
*   *For driver compiler settings, see the [GPU Operator Guide](interview-notes/gpu-operator.md).*

### Lessons Learned
*   Dynamic driver compilation slows down cluster scaling. Pre-bake kernel drivers into node images for production networks.

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
*   **Malformed Configuration:** The ConfigMap data block lacked the `resources` map array list or used incorrect keys.
*   **Namespace Mismatch:** The ConfigMap was created in a separate namespace (`default`) rather than the `gpu-operator` namespace.

### Resolution
*   Re-deploy the ConfigMap to the correct namespace and patch the policy:
    ```yaml
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: device-plugin-config
      namespace: gpu-operator
    data:
      time-slicing-config: |-
        version: v1
        sharing:
          timeSlicing:
            resources:
              - name: nvidia.com/gpu
                replicas: 4
    ```
*   *For virtualization limitations, see the [Virtualization Models Guide](interview-notes/time-slicing.md).*

### Lessons Learned
*   Validate configurations against the official schemas. Keep configuration resources co-located inside the Operator namespace.

---

## Related Documentation
*   **System Layouts:** [Architecture Topology](architecture.md) | [Performance Profiling](performance.md) | [Future Roadmap](roadmap.md)
*   **Conceptual Focus:** [Device Plugin Interface](interview-notes/device-plugin.md) | [GPU Operator Internals](interview-notes/gpu-operator.md) | [Virtualization Models](interview-notes/time-slicing.md) | [Karpenter Scheduling](interview-notes/karpenter.md)
*   **Journal Logs:** [Post-Mortems & Lessons Learned](lessons-learned.md)
