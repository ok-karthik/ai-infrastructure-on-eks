# Engineering Journal: Post-Mortems & Lessons Learned

This journal documents the actual troubleshooting sessions, post-mortems, and engineering insights gained during the development and optimization of the AI Infrastructure Platform on Amazon EKS.

---

## 1. Post-Mortem: Broken ClusterPolicy After Enabling Time-Slicing

### Background
To support multi-tenant workloads, we attempted to enable GPU Time-Slicing on the EKS cluster. We created a custom ConfigMap with a division factor of 4 and patched the GPU Operator `ClusterPolicy` to load this configuration.

### Incident
Immediately after applying the patch, all GPU nodes transitioned their `nvidia.com/gpu` capacity to `0`. All pending and running GPU pods stalled or crashed. The GPU Operator pods fell into a loop, continually trying to reconcile resources.

### Debugging Steps
1.  **Check ClusterPolicy Status:**
    ```bash
    kubectl get clusterpolicy default -o yaml
    ```
    We observed that the `devicePlugin` reconciliation loop reported status: `Error: failed to reconcile device-plugin daemonset: ConfigMap "time-slicing-config" not found`.
2.  **Verify ConfigMap Namespace:**
    We checked where the ConfigMap was created:
    ```bash
    kubectl get configmap -A | grep time-slicing
    ```
    *Discovery:* The ConfigMap was mistakenly deployed in the `default` namespace, while the GPU Operator is hosted in the `gpu-operator` namespace. The operator was looking inside its own namespace and couldn't find the configuration.

### Resolution
Redeploy the ConfigMap explicitly inside the `gpu-operator` namespace and trigger a restart of the operator:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: device-plugin-config
  namespace: gpu-operator
...
```

### Key Lesson
Kubernetes Operator components expect dependent configuration objects (like ConfigMaps or Secrets) to exist inside the operator's home namespace unless a cross-namespace reference parameter is explicitly supported.

---

## 2. Post-Mortem: Fixing the Malformed ConfigMap (Missing `resources`)

### Background
We attempted to deploy a configuration to divide physical GPUs.

### Incident
The ConfigMap was successfully created in the correct `gpu-operator` namespace, and the `ClusterPolicy` reconciled. However, the nodes still advertised only `1` GPU instead of `4`. The Device Plugin container logs reported:
```text
Error parsing time-slicing configuration: no resources specified
```

### Debugging Steps
1.  **Examine ConfigMap Data:**
    ```bash
    kubectl get configmap -n gpu-operator device-plugin-config -o yaml
    ```
2.  **Compare with Schema Specs:**
    We compared our YAML with the official NVIDIA documentation.
    *Discovery:* We had written the replicas block directly under `sharing.timeSlicing` without the nested `resources` list.
    *Malformed YAML:*
    ```yaml
    sharing:
      timeSlicing:
        name: nvidia.com/gpu
        replicas: 4
    ```
    The parser checks for a list under `resources`. Since it couldn't find it, it raised a parsing warning and ignored the configuration.

### Resolution
Corrected the nesting structure:
```yaml
sharing:
  timeSlicing:
    resources:
      - name: nvidia.com/gpu
        replicas: 4
```

### Key Lesson
Configuration parameters for low-level device plugins are strict. Validate configurations against official schema configurations before updating active configurations.

---

## 3. Post-Mortem: Device Plugin & GPU Feature Discovery CrashLoopBackOff

### Background
Newly provisioned GPU worker nodes were joining the cluster via Karpenter scale-up.

### Incident
The nodes registered, but the GPU Feature Discovery (GFD) and Device Plugin pods constantly crashed, remaining in `CrashLoopBackOff` status. The node labels and allocatable capacity were not updated.

### Debugging Steps
1.  **Check Pod Logs:**
    ```bash
    kubectl logs -n gpu-operator -l app=nvidia-gpu-feature-discovery
    ```
    Error output:
    ```text
    Error: failed to write labels: permission denied /etc/kubernetes/node-feature-discovery/features.d/
    ```
2.  **Investigate Host Paths:**
    The host path `/etc/kubernetes/node-feature-discovery/features.d/` is used by NFD to write dynamic node features. On our Amazon Linux 2023 nodes, this folder had strict `root:root` write limits. The GFD container was running under a restricted security context, blocking it from executing write calls.

### Resolution
Configure the GFD and NFD DaemonSets in the `ClusterPolicy` to run with root permissions and privileged security contexts:
```yaml
spec:
  devicePlugin:
    securityContext:
      privileged: true
  gfd:
    securityContext:
      privileged: true
```

### Key Lesson
Low-level hardware discovery and interface plugins must run with privileged host context permissions to interact with host device paths and sockets.

---

## 4. Post-Mortem: Why Karpenter Created an Extra GPU Node

### Background
We launched a job requesting a single GPU, expecting Karpenter to boot 1 node and execute the workload.

### Incident
Karpenter scaled up a GPU node (`g4dn.xlarge`). However, immediately after it booted, Karpenter launched a *second* GPU node. The first node remained underutilized, running standard CPU pods.

### Debugging Steps
1.  **Analyze Karpenter Scheduling Decisions:**
    ```bash
    kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --tail=100
    ```
    *Discovery:* The first GPU node booted. However, because our GPU pod did not declare a strict Node Selector or Node Affinity (only a Toleration), other standard CPU pods in the cluster scheduled on the newly booted GPU node, filling its remaining CPU limits. 
    When the second GPU workload pod arrived, the first GPU node had plenty of physical GPU capacity left, but its *CPU allocatable space* was fully exhausted. Karpenter was forced to launch a second GPU node to satisfy the CPU request of the second GPU pod.

### Resolution
Enforce Node Selectors on the GPU workloads so only pods requiring GPUs can schedule on those nodes, and configure CPU resource requests properly.
```yaml
nodeSelector:
  accelerator: nvidia-gpu
```

### Key Lesson
GPU nodes are multi-resource machines. CPU and memory capacities can become bottlenecks before GPU capacity is exhausted. Enforce strict selectors to isolate compute.

---

## 5. Post-Mortem: Why DCGM Metric Exporters Showed Only a Single Pod Under Time-Slicing

### Background
We scheduled 4 concurrent workloads on a single physical GPU partitioned via Time-Slicing.

### Incident
When reviewing Prometheus queries, the `dcgm_sm_copy` metric showed only 1 pod label, while the other 3 pods reported empty namespace and pod metadata.

### Debugging Steps
1.  **Verify Pod-to-GPU mapping:**
    We confirmed all 4 pods were running and consuming GPU capacity.
2.  **Investigate Exporter Mapping Logic:**
    The DCGM Exporter queries Kubelet's `/var/lib/kubelet/pod-resources/kubelet.sock` to map container cgroups to GPU UUIDs.
    *Discovery:* Under Time-Slicing, all 4 containers are mapped to the identical physical GPU device UUID (`GPU-70e2...`). The exporter associates the UUID with the first pod it queries from Kubelet. Since it maps 1:1, it associates the GPU metrics only with the first pod it finds, leaving the other 3 pods unmapped.

### Resolution
This is a design limitation of GPU Time-Slicing. To track per-pod metrics, you must use MIG (Multi-Instance GPU), which exposes distinct physical hardware instances per container.

---

## 6. Post-Mortem: Why `nvidia-smi` Reported No Processes inside Containers

### Background
We ran a heavy CUDA training run inside a pod.

### Incident
When executing `nvidia-smi` from inside the workload container, the top panel showed high SM usage, but the bottom processes list reported:
```text
No running processes found
```

### Debugging Steps
1.  **Verify Container Process Namespace:**
    We verified that the CUDA job was indeed executing and consuming resources.
2.  **Investigate PID namespaces:**
    By default, Kubernetes isolates container PID namespaces. The process executing CUDA runs inside the container's PID namespace (e.g. PID 1), but the NVIDIA host driver reads PID listings from the host's root namespace (PID namespace 1). Since the container is isolated, the driver cannot map the container process ID to the host namespace list, resulting in an empty process table.

### Resolution
To see container processes in `nvidia-smi` for diagnostic purposes, configure the pod spec to share the host's PID namespace:
```yaml
spec:
  hostPID: true
```

### Key Lesson
Process namespace isolation in Kubernetes masks container IDs from host drivers. Share PID namespaces only during diagnostic investigations, as it compromises isolation boundaries.
