# Production Troubleshooting & Failure Modes Runbook

This runbook catalogs the real-world operational issues, diagnostic workflows, and structural resolutions encountered when operating GPU infrastructure on Amazon EKS.

---

## 1. Karpenter Launches Unexpected GPU Node

### Symptoms
Karpenter scales up an expensive GPU instance (e.g. `g4dn.xlarge`) for a workload that does not require GPU compute, or scales up a GPU node for a CPU-only workload.

### Investigation
Inspect Karpenter controller logs to identify which scheduling constraint or pod toleration triggered the scale-up request.
```bash
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --tail=100 -f
```
Check the pending pod's resource requests and tolerations:
```bash
kubectl get pod <pod-name> -o yaml
```

### Root Cause
1.  **Missing Node Selector:** The pod did not declare a node selector (e.g. `accelerator: nvidia-gpu`) but had a wild-card toleration or tolerated the GPU taint (`nvidia.com/gpu:NoSchedule`). Karpenter evaluated that the pod was schedulable on the GPU NodePool and selected it.
2.  **Missing Taint Isolation:** The Karpenter `NodePool` definition was missing the `taints` block, allowing standard workloads to schedule on GPU compute resources.

### Resolution
Ensure all GPU Karpenter `NodePool` specs declare the standard taint:
```yaml
spec:
  template:
    spec:
      taints:
        - key: nvidia.com/gpu
          value: "true"
          effect: NoSchedule
```
Update workloads to require both the toleration and the matching selector:
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
Always enforce taints on expensive compute classes. In multi-tenant environments, implement Kubernetes Gatekeeper or Kyverno policies to reject workloads that attempt to tolerate GPU taints without explicitly requesting GPU resources.

---

## 2. NVIDIA Device Plugin CrashLoopBackOff

### Symptoms
The `nvidia-device-plugin-daemonset` pods on GPU-enabled nodes enter a `CrashLoopBackOff` state.

### Investigation
Retrieve logs from the crashing container:
```bash
kubectl logs -n gpu-operator -l app=nvidia-device-plugin-daemonset --tail=50
```
Common error output:
```text
Error: failed to connect to Kubelet: connection refused
or
Error: list of devices is empty (no GPUs found)
```
Check host drivers:
```bash
kubectl exec -n gpu-operator ds/nvidia-driver-daemonset -- nvidia-smi
```

### Root Cause
1.  **Drivers Not Ready:** The Device Plugin started before the GPU Operator completed driver installation. The kernel driver paths (`/dev/nvidia*`) did not exist on the host file system.
2.  **Kubelet Socket Access:** The daemonset was blocked from writing to the kubelet socket (`/var/lib/kubelet/device-plugins/kubelet.sock`) due to restrictive SELinux/AppArmor settings or incorrect hostPath volumes.

### Resolution
1.  Verify the GPU Operator `ClusterPolicy` is set to manage drivers correctly.
2.  Check that the daemonset has correct security contexts and volume mounts:
```yaml
securityContext:
  privileged: true
volumeMounts:
  - name: device-plugin
    mountPath: /var/lib/kubelet/device-plugins
```

### Lessons Learned
Utilize initContainers in daemonsets to block execution until critical host dependencies (like driver files under `/dev/nvidiactl`) are present.

---

## 3. Pods Stuck in Pending (GPU Not Allocated)

### Symptoms
Workload pods requesting GPUs remain in a `Pending` state. `kubectl describe pod` outputs:
```text
0/3 nodes are available: 3 Insufficient nvidia.com/gpu.
```

### Investigation
Check node allocatable resources:
```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU_ALLOCATABLE:.status.allocatable."nvidia\.com/gpu"
```
If the column is empty or `0`, check the state of the Node Feature Discovery labels:
```bash
kubectl get nodes --show-labels | grep nvidia
```
Verify the container runtime matches:
```bash
kubectl describe node <gpu-node> | grep -A 10 Capacity
```

### Root Cause
1.  **NFD Discovery Failed:** NFD did not label the node with `feature.node.kubernetes.io/pci-10de.present=true`, so the GPU Operator skipped deploying components to that node.
2.  **Container Runtime Configuration:** The Container Toolkit failed to register the `nvidia` runtime configuration with `containerd`, leaving Kubelet unable to map GPU devices.

### Resolution
Restart NFD pods to force a hardware scan:
```bash
kubectl rollout restart daemonset -n gpu-operator node-feature-discovery
```
Verify that `/etc/containerd/config.toml` on the node contains the nvidia runtime plugin:
```toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia]
  privileged_without_host_devices = false
  runtime_type = "io.containerd.runc.v2"
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia.options]
    BinaryName = "/usr/bin/nvidia-container-runtime"
```

### Lessons Learned
Kubelet depends entirely on the device plugin to advertise hardware capacity. If the plugin fails silently, the scheduler acts as if the nodes have no GPUs. Set up alerts on cluster capacity metrics (`kube_node_status_allocatable`).

---

## 4. GPU Operator Stuck in Reconciling / Init Container Fails

### Symptoms
The GPU Operator Helm release or ClusterPolicy resources are stuck in `Reconciling` or `InProgress`. Operator validation pods fail during initialization.

### Investigation
Describe the operator pods and the ClusterPolicy custom resource:
```bash
kubectl get clusterpolicy -o yaml
kubectl describe pod -n gpu-operator -l app.kubernetes.io/component=gpu-operator
```
Check driver container build logs (especially if using pre-compiled driver options):
```bash
kubectl logs -n gpu-operator -l app=nvidia-driver-daemonset -c nvidia-driver
```

### Root Cause
1.  **Kernel Version Mismatch:** The target node runs a newer OS kernel than the pre-compiled driver image supports. The driver container fails to build or load the kernel module.
2.  **No Internet Egress:** The driver compiler container requires package updates (e.g., `kernel-devel` or `elfutils`) to compile the driver. If the node runs in a private subnet without internet egress, these package downloads fail.

### Resolution
1.  Ensure Karpenter targets AMIs that match the GPU Operator's driver compatibility matrix.
2.  Host driver compilers locally or pre-bake the driver modules directly into the node AMI (e.g. using the official AWS EKS AL2023 GPU AMI).
3.  Configure proxies or private endpoints for package repositories.

### Lessons Learned
Compiling GPU drivers at node boot time introduces significant compute startup latency and external dependencies. Pre-bake kernel drivers into the custom cluster AMI for production environments.

---

## 5. GPU Time-Slicing Doesn't Partition Resources

### Symptoms
Workload pods request virtual GPUs (e.g. `nvidia.com/gpu: 1`), but the physical node only advertises the actual physical GPU count (e.g. 1 GPU instead of the configured 4 virtual slices).

### Investigation
Check the ConfigMap containing time-slicing configurations:
```bash
kubectl get configmap -n gpu-operator time-slicing-config -o yaml
```
Check if the GPU Operator has time-slicing enabled in the `ClusterPolicy`:
```bash
kubectl get clusterpolicy default -o jsonpath='{.spec.devicePlugin.config.name}'
```
Inspect Device Plugin logs for config errors:
```bash
kubectl logs -n gpu-operator -l app=nvidia-device-plugin-daemonset
```

### Root Cause
1.  **Mismatched ConfigMap Key:** The ConfigMap key name did not match the configuration reference in the `ClusterPolicy`.
2.  **Syntax Error:** The YAML indentation inside the ConfigMap data block was incorrect, causing the Device Plugin to fail validation and fall back to physical GPU mode.

### Resolution
Apply a correct ConfigMap and reference it in the `ClusterPolicy`:
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
Ensure the `ClusterPolicy` is updated:
```yaml
spec:
  devicePlugin:
    config:
      name: device-plugin-config
      default: time-slicing-config
```

### Lessons Learned
Time-slicing configurations must be applied globally or via node-specific profile matchers. Monitor the `nvidia.com/gpu` capacity count on nodes immediately after applying the configurations.

---

## 6. DCGM Exporter Metrics Missing or Prometheus Fails to Scrape

### Symptoms
GPU metrics (e.g. `DCGM_FI_DEV_GPU_TEMP`, `DCGM_FI_DEV_GPU_UTIL`) are missing from Prometheus target lists or Grafana panels are empty.

### Investigation
Check if the DCGM Exporter daemonset pods are running:
```bash
kubectl get pods -n gpu-operator -l app.kubernetes.io/name=nvidia-dcgm-exporter
```
Test metric generation from inside the cluster using curl:
```bash
kubectl run curl-test --image=curlimages/curl -i --rm --restart=Never -- \
  curl -s http://nvidia-dcgm-exporter.gpu-operator.svc.cluster.local:9400/metrics
```
Verify Prometheus scrape targets:
```bash
kubectl get service -n gpu-operator -l app.kubernetes.io/name=nvidia-dcgm-exporter
```

### Root Cause
1.  **Missing Service Monitor / Annotations:** Prometheus was not configured to discover the DCGM exporter service because it lacked the correct scrape annotations or a `ServiceMonitor` resource.
2.  **NetworkPolicies Blocking Scrapes:** restrictive network policies in the `gpu-operator` namespace blocked traffic from the `prometheus` namespace to port `9400`.

### Resolution
Add appropriate annotations to the DCGM Exporter service:
```yaml
metadata:
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "9400"
```
Or define a clean `ServiceMonitor`:
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: dcgm-exporter
  namespace: gpu-operator
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: nvidia-dcgm-exporter
  endpoints:
    - port: metrics
      interval: 5s
```

### Lessons Learned
Scrape intervals for GPU metrics should be frequent (e.g., 5 seconds) to catch peak transient loads like SM spikes, which are easily smoothed out and hidden under standard 30-second scrape intervals.

---

## 7. Node Becomes NotReady under High CUDA Load

### Symptoms
Under execution load (e.g., LLM training or heavy parallel matrix multiplication), the EKS node transitions to a `NotReady` status. Pods reschedule, and `syslog` reports kernel panics.

### Investigation
Connect to the node serial console or examine system logs via SSH:
```bash
dmesg -T | grep -i "nvidia"
cat /var/log/messages | grep -E "NVRM|GPU"
```
Check host thermal/throttling state:
```bash
nvidia-smi -q -d PERFORMANCE,TEMPERATURE
```

### Root Cause
1.  **Thermal Throttling / HW Fault:** The physical GPU reached critical temperature limits due to poor chassis airflow, triggering a hardware protection shutdown.
2.  **Out-Of-Memory (OOM) Killer:** The CUDA process allocated host memory beyond EKS limitations, forcing the kernel OOM killer to terminate critical OS daemons like `kubelet` or `containerd`.

### Resolution
1.  Implement strict memory resource limits (`limits.memory`) on all pods to protect host memory.
2.  Set up alarms on the DCGM throttling metric:
    -   `DCGM_FI_DEV_THERMAL_VIOLATION` (thermal limit reached)
    -   `DCGM_FI_DEV_POWER_VIOLATION` (power limit reached)
3.  Configure Karpenter to monitor node degradation metrics and isolate nodes experiencing hardware faults.

### Lessons Learned
Hardware health monitoring is just as critical as capacity planning. Ensure system-level metrics like GPU error codes (e.g., PCIe errors, XID errors) are scraped and alerted on.
