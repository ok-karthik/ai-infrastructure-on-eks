# Engineering Journal: Post-Mortems & Lessons Learned

This journal documents the troubleshooting sessions and post-mortems resolved during the optimization of the AI Infrastructure Platform on Amazon EKS.

---

## 1. Post-Mortem: Broken ClusterPolicy After Enabling GPU Time Slicing

### Incident
After applying a GPU Time Slicing configuration, the EKS nodes reported `nvidia.com/gpu: 0` allocatable capacity. Active GPU workloads failed scheduling. The GPU Operator entered a reconciliation loop error state.

### Diagnostic Steps
*   **Purpose:** Inspect ClusterPolicy resource status logs.
    *   **Command:**
        ```bash
        kubectl get clusterpolicy default -o yaml
        ```
    *   **Expected Result:** The `devicePlugin` section status contains a configuration error.
    *   **Validation:** Verify error: `ConfigMap "time-slicing-config" not found`.
*   **Purpose:** Search for the ConfigMap placement.
    *   **Command:**
        ```bash
        kubectl get configmap -A | grep time-slicing
        ```
    *   **Expected Result:** ConfigMap discovered in the `default` namespace.
    *   **Validation:** Confirm the GPU Operator is in `gpu-operator` and cannot read across namespaces.

### Resolution
*   Re-deploy the ConfigMap to the `gpu-operator` namespace.
    ```yaml
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: device-plugin-config
      namespace: gpu-operator
    ```

### Lessons Learned
*   Operator configurations must exist in the operator's namespace to be visible to the reconciliation controllers.

---

## 2. Post-Mortem: Fixing Malformed ConfigMap (Missing `resources`)

### Incident
The ConfigMap was placed in the `gpu-operator` namespace, but the node advertised only `1` GPU instead of `4` virtual slices. Exporter logs reported: `no resources specified`.

### Diagnostic Steps
*   **Purpose:** Verify ConfigMap data.
    *   **Command:**
        ```bash
        kubectl get configmap -n gpu-operator device-plugin-config -o yaml
        ```
    *   **Expected Result:** YAML block missing nesting constraints.
    *   **Validation:** Checked structure against NVIDIA's specifications, identifying that `replicas` was declared without the nesting array key `resources`.

### Resolution
*   Adjusted YAML mapping keys:
    ```yaml
    sharing:
      timeSlicing:
        resources:
          - name: nvidia.com/gpu
            replicas: 4
    ```

### Lessons Learned
*   Verify configuration structures against schema files before deploying to cluster environments.

---

## 3. Post-Mortem: GPU Feature Discovery CrashLoopBackOff

### Incident
Newly provisioned GPU worker nodes joined the cluster but Node Feature Discovery (NFD) and Kubernetes Device Plugin pods entered `CrashLoopBackOff`. Node capacity remained unadvertised.

### Diagnostic Steps
*   **Purpose:** Retrieve logs from the failing NFD helper container.
    *   **Command:**
        ```bash
        kubectl logs -n gpu-operator -l app=nvidia-gpu-feature-discovery
        ```
    *   **Expected Result:** IO permission write failures.
    *   **Validation:** Verify error: `failed to write labels: permission denied /etc/kubernetes/node-feature-discovery/features.d/`.

### Resolution
*   Re-configure the GPU Operator's `ClusterPolicy` to run helper daemons with root execution contexts:
    ```yaml
    spec:
      devicePlugin:
        securityContext:
          privileged: true
      gfd:
        securityContext:
          privileged: true
    ```

### Lessons Learned
*   Hardware discovery agents require privileged host path mounts to write telemetry and capability labels to the node.

---

## 4. Post-Mortem: Unexpected Dynamic Scaling Node Launch

### Incident
Scheduling a single GPU pod caused Karpenter to provision *two* EKS GPU instances, leaving the first instance underutilized.

### Diagnostic Steps
*   **Purpose:** Inspect Karpenter scheduling logs.
    *   **Command:**
        ```bash
        kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --tail=100
        ```
    *   **Expected Result:** Node allocation logs detailing scaling reasons.
    *   **Validation:** Identified that CPU-only workloads scheduled on the first GPU instance because it lacked strict selectors. When the second GPU pod arrived, the first GPU host was out of CPU capacity, forcing another node launch.

### Resolution
*   Configure all GPU jobs with strict node selectors to prevent standard workloads from occupying CPU capacities:
    ```yaml
    nodeSelector:
      accelerator: nvidia-gpu
    ```

### Lessons Learned
*   Enforce strict node selectors and taints to isolate multi-resource GPU machines from CPU workloads.

---

## 5. Post-Mortem: Single Pod Label under GPU Time Slicing

### Incident
When running 4 concurrent pods sharing a GPU, Prometheus queries only returned pod and namespace metadata labels for the first pod.

### Diagnostic Steps
*   **Purpose:** Check pod process execution.
    *   **Command:**
        ```bash
        kubectl get pods -l app=gpu-load-test
        ```
    *   **Expected Result:** 4 pods reported as running.
    *   **Validation:** Checked the NVML socket mapper mapping database, discovering that the cgroup-to-UUID link maps 1:1, binding the metric to the first container queried.

### Resolution
*   Acknowledge Time Slicing cgroup metric limitations. Migrate to Multi-Instance GPU (MIG) when strict per-container usage reporting is required.

---

## 6. Post-Mortem: nvidia-smi Reports No Processes inside Container

### Incident
Workloads execute CUDA calculations, but running `nvidia-smi` inside the container reports: `No running processes found`.

### Diagnostic Steps
*   **Purpose:** Verify PID namespace isolation settings.
    *   **Command:**
        ```bash
        kubectl exec <pod-name> -- ps -ef
        ```
    *   **Expected Result:** List of running container processes.
    *   **Validation:** Process namespace isolation (PID 1 mapping inside containerd) hides container process IDs from the host driver's reporting mechanisms.

### Resolution
*   In diagnostic environments, allow host PID namespace sharing:
    ```yaml
    spec:
      hostPID: true
    ```

### Lessons Learned
*   Isolation layers mask container context from drivers. Limit host PID sharing to debug sessions.

---

## Related Documentation
*   **Technical Designs:** [Architecture Topology](architecture.md) | [Performance Profiling](performance.md) | [Future Roadmap](roadmap.md)
*   **Conceptual Focus:** [Device Plugin Interface](interview-notes/device-plugin.md) | [GPU Operator Internals](interview-notes/gpu-operator.md) | [Virtualization Models](interview-notes/time-slicing.md) | [Karpenter Scheduling](interview-notes/karpenter.md)
*   **Operational Guides:** [Troubleshooting Runbook](troubleshooting.md) | [Hands-on Labs Index](hands-on-labs.md)
