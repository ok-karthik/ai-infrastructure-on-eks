# Lab 6: Production Troubleshooting & Chaos Recovery

## Objective
Investigate, diagnose, and recover from real production failure modes encountered when managing GPU clusters. This guide contains detailed incident reports covering container runtime loops, invalid virtual partition configurations, driver faults, and autoscaler runaways.

---

## 1. NVIDIA Device Plugin CrashLoopBackOff

### Symptoms
The `nvidia-device-plugin-daemonset` pods on GPU-enabled nodes crash continuously, reporting `CrashLoopBackOff` in `kubectl get pods`.

### Investigation
Inspect the logs of the crashing pod:
```bash
kubectl logs -n gpu-operator -l app=nvidia-device-plugin-daemonset --tail=30
```
Standard output:
```text
Error: failed to connect to Kubelet: connection refused
or
Error: list of devices is empty (no GPUs found)
```
Check if host kernel modules are loaded:
```bash
kubectl exec -n gpu-operator ds/nvidia-driver-daemonset -- nvidia-smi
```

### Root Cause
1.  **Driver Module Not Loaded:** The Device Plugin container booted before the Driver Installer container completed compilation and insertion of `nvidia.ko`. The `/dev/nvidiactl` device node did not exist on the host filesystem.
2.  **SELinux / AppArmor Restriction:** Host security policies blocked Kubelet's UNIX socket communication with the plugin socket at `/var/lib/kubelet/device-plugins/kubelet.sock`.

### Resolution
Apply initialization checkpoints to the Device Plugin DaemonSet. Ensure the container waits for driver endpoints:
```yaml
initContainers:
  - name: wait-for-driver
    image: busybox:1.36
    command: ['sh', '-c', 'until [ -e /dev/nvidiactl ]; do echo waiting for nvidia driver; sleep 5; done']
```

### Lessons Learned
Always implement initialization guards (initContainers) in device plugins to prevent boots before host drivers are fully initialized.

---

## 2. Invalid GPU Time-Slicing ConfigMap (No Resources Specified)

### Symptoms
After applying a GPU Time-Slicing configuration, the node capacity remains stuck at `nvidia.com/gpu: 1` instead of updating to the replicated capacity (e.g., `4`).

### Investigation
Check the ConfigMap structure applied to the cluster:
```bash
kubectl get configmap -n gpu-operator device-plugin-config -o yaml
```
Examine Device Plugin daemon logs for syntax validation errors:
```bash
kubectl logs -n gpu-operator -l app=nvidia-device-plugin-daemonset | grep -i config
```
Standard log error:
```text
Error parsing time-slicing configuration: no resources specified
```

### Root Cause
The configuration YAML structure inside the ConfigMap data block was malformed or missing the `resources` list. The plugin parser expects a defined schema matching NVIDIA's configuration specification. An incorrect or empty key mapping causes the plugin to fall back silently to single physical GPU mode.

*Malformed Config example:*
```yaml
# MALFORMED CONFIG: Missing resource list declaration
sharing:
  timeSlicing:
    replicas: 4
```

### Resolution
Re-apply a configuration conforming to the official schema:
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

### Lessons Learned
Validating custom resource configurations against JSON schemas before applying them prevents silent parsing failures. Maintain schema validation checks in CI pipelines.

---

## 3. GPU Feature Discovery (GFD) CrashLoopBackOff

### Symptoms
The GPU Feature Discovery pods, which run as a DaemonSet to write hardware details as labels, crash during start-up.

### Investigation
Retrieve logs from the GFD container:
```bash
kubectl logs -n gpu-operator -l app=nvidia-gpu-feature-discovery --tail=50
```
Common error output:
```text
Error: failed to write labels: permission denied /etc/kubernetes/node-feature-discovery/features.d/
```

### Root Cause
The Node Feature Discovery and GFD daemons require write access to the host's directory `/etc/kubernetes/node-feature-discovery/features.d/` to publish custom properties. If the host filesystem mount lacks write permissions or the pod runs under an restricted Security Context Constraint (SCC), the write operation fails.

### Resolution
Ensure that the NFD and GFD DaemonSets are run with appropriate security contexts and host directory write privileges:
```yaml
securityContext:
  privileged: true
```
Ensure directory volume mounts are read-write:
```yaml
volumeMounts:
  - name: features-dir
    mountPath: /etc/kubernetes/node-feature-discovery/features.d/
    readOnly: false
```

### Lessons Learned
Security policies (like PSP, Pod Security Standards, or OPA) must permit privileged execution context for hardware Discovery agents to execute system write calls.

---

## 4. Node Transitions to NotReady Under Load

### Symptoms
EKS worker nodes running heavy LLM or training tasks suddenly transition to a `NotReady` status. Workload pods stall or reschedule, and Kubelet logs report timeout failures.

### Investigation
Connect to the host node's system logger or examine the system console output:
```bash
dmesg -T | grep -i -E "NVRM|GPU|PCI"
```
Look for lines reporting driver timeout events:
```text
NVRM: Xid (PCI:0000:00:1e): 45, Chid 00000008, Err {Power/Thermal/Bus Link Failure}
```

### Root Cause
1.  **Thermal Throttling / Hardware Failure:** High compute loads caused the GPU to exceed physical safety temperature bounds, triggering a hardware protection shutdown and drop off the PCIe bus.
2.  **Kubelet Memory Exhaustion:** Host memory was exhausted because the pod lacked memory limit enforcements, causing the OS kernel OOM killer to terminate the `kubelet` process.

### Resolution
1.  Enforce resource limit blocks (`limits.memory`) on all workload manifests.
2.  Set up alarms on the DCGM throttling metric:
    -   `DCGM_FI_DEV_THERMAL_VIOLATION` (thermal limit reached)
    -   `DCGM_FI_DEV_POWER_VIOLATION` (power limit reached)
3.  Configure Karpenter to monitor node degradation metrics and isolate nodes experiencing hardware faults.

### Lessons Learned
Hardware health monitoring is just as critical as capacity planning. Ensure system-level metrics like GPU error codes (e.g., PCIe errors, XID errors) are scraped and alerted on.

---

## 5. Unexpected GPU Node Provisioning by Karpenter

### Symptoms
Karpenter spins up multiple GPU worker nodes when only a single node was expected or needed.

### Investigation
Trace Karpenter scheduling logs:
```bash
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter
```
Examine pod request parameters:
```bash
kubectl get pods -A -o custom-columns=NAME:.metadata.name,GPU_REQ:.spec.containers[*].resources.requests
```

### Root Cause
1.  **Missing Node Selector:** Pods requesting `nvidia.com/gpu` lacked node selectors (like `accelerator: nvidia-gpu`). Karpenter scheduled them on the node, but after the node booted, other standard pods filled up the remaining CPU/Memory on the GPU node. When the second GPU pod arrived, the first GPU node had no CPU space left, forcing Karpenter to provision a second GPU node.
2.  **Toleration without Limits:** Standard CPU workloads tolerated the GPU taint. When CPU capacity ran tight, Karpenter scheduled CPU pods on the GPU node, filling its CPU limits and blocking incoming GPU workloads.

### Resolution
1.  Apply strict taints to the GPU `NodePool`.
2.  Ensure all GPU workloads declare matching node selectors:
```yaml
nodeSelector:
  accelerator: nvidia-gpu
```

### Lessons Learned
A GPU node is a multi-resource machine. Ensure CPU/Memory sizes on GPU NodePools are scaled appropriately, and enforce node selectors to isolate resources.

---

## 6. Per-Pod DCGM Metrics Missing under Time-Slicing

### Symptoms
Prometheus reports `dcgm_sm_copy` metrics for the node, but the `pod` and `container` labels are empty or missing, preventing per-pod execution tracking.

### Investigation
Check DCGM Exporter query configurations:
```bash
kubectl exec -n gpu-operator daemonset/nvidia-dcgm-exporter -- curl -s localhost:9400/metrics | grep dcgm_sm_copy
```
Identify that only one pod annotation is printed, even though multiple pods run on the GPU.

### Root Cause
Under GPU Time-Slicing, multiple pods share the identical physical GPU device namespace. The hardware execution unit (Streaming Multiprocessor) context-switches at the driver level and does not distinguish container cgroup namespaces. Therefore, DCGM can only report performance metrics for the *physical* device as a whole. It cannot isolate metrics per container.

### Resolution
1.  Explain this limitation to workload teams.
2.  To track exact per-pod metrics, partition the physical GPU using **Multi-Instance GPU (MIG)**, which exposes distinct physical device paths for each container cgroup.

---

## 7. Grafana Dashboard Investigation & Prometheus Scrape Limitations

### Symptoms
The Grafana dashboard shows empty panels or flatlines for GPU metrics under peak execution loads.

### Investigation
Check the Prometheus scrape configuration for the exporter target:
```bash
kubectl get service -n gpu-operator nvidia-dcgm-exporter -o yaml
```
Ensure the scrape interval is set appropriately. Verify metric query strings in Grafana:
```promql
# Query for GPU SM utilization
avg(dcgm_sm_copy{modelName=~"Tesla.*"}) by (pod)
```

### Root Cause
1.  **Scrape Interval Too Long:** If the Prometheus scrape interval is set to 30s, short transient GPU workloads (e.g. 5-second matrix multiplies) are missed or flattened out.
2.  **Mismatched Model Variables:** Grafana dashboard variables were configured for `A100` models, while the cluster ran `Tesla T4` instances, breaking query filtering.

### Resolution
1.  Configure Prometheus scrape configurations specifically for DCGM:
```yaml
scrape_configs:
  - job_name: 'dcgm-exporter'
    scrape_interval: 5s # Set high-resolution scrape interval
    static_configs:
      - targets: ['nvidia-dcgm-exporter.gpu-operator.svc.cluster.local:9400']
```
2.  Generalize Grafana dashboard variables using regex matchers like `.*` to fit any GPU type.

---

## Interview Takeaways

*   **ホワイトボード: Discussing Production Failure Modes:**
    *   Be ready to diagram how a container runtime failure (containerd loop) halts Kubelet communication. Explain how the NVIDIA Container Toolkit patches cgroups, and how a bad configuration locks CRI access.
*   **Time-Slicing vs MIG Telemetry:** Explain that Time-Slicing prevents per-pod VRAM metrics. Since VRAM is shared globally, you cannot monitor individual model memory usage via DCGM. Explain that MIG must be used if strict allocation auditing is required.
*   **Incident Recovery Steps:** Detail the steps to recover a crashed GPU node: cordon the node, drain active pods (rescheduling them to other nodes via Karpenter), run validation container checks, and reboot the physical instance.
