# Hands-On Infrastructure & Operations Labs

This guide contains 15 sequential hands-on labs designed to validate platform capabilities, troubleshoot complex failure states, and perform chaos engineering experiments on the EKS GPU platform.

---

## Lab 1: Provision GPU Node with Karpenter

### Objective
Trigger Karpenter to provision a GPU-optimized EC2 instance (`g4dn.xlarge`) dynamically by scheduling a pod that requests a GPU.

### Architecture
```text
GPU Pod Request -> Karpenter Intercepts -> Matches NodePool Requirements -> Calls AWS EC2 API -> Boots g4dn.xlarge Spot Instance
```

### Commands
Apply the Karpenter GPU NodePool:
```bash
kubectl apply -f 02-platform/karpenter/karpenter-gpu-nodeclass.yaml
kubectl apply -f 02-platform/karpenter/karpenter-gpu-nodepool.yaml
```
Create a workload request:
```bash
kubectl apply -f 03-workloads/gpu-test-pod-workloads.yaml
```

### Expected Output
Karpenter controller logs:
```text
2026-07-15T20:10:00Z INFO karpenter.scheduler Found 1 pending pod(s) requesting nvidia.com/gpu
2026-07-15T20:10:01Z INFO karpenter.cloudprovider Created nodeclaim gpu-pool-xxxxx with instance g4dn.xlarge, zone us-east-1a, capacity-type spot
```

### Verification
Verify node boot:
```bash
kubectl get nodes -l accelerator=nvidia-gpu -w
```

### Cleanup
Delete the pod:
```bash
kubectl delete -f 03-workloads/gpu-test-pod-workloads.yaml
```

### Lessons
Karpenter evaluates pod specifications against active NodePool filters to choose the most cost-efficient instance. Isolating node creation prevents idle runtime bills.

---

## Lab 2: Install GPU Operator

### Objective
Install the NVIDIA GPU Operator via Helm to configure driver management and toolkit components.

### Architecture
```text
GPU Operator Pod -> ClusterPolicy CRD -> Provisions Driver, Toolkit, and Validation DaemonSets to GPU nodes
```

### Commands
Initialize the GPU Operator:
```bash
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia-dev
helm repo update
helm install gpu-operator nvidia/gpu-operator \
  --namespace gpu-operator \
  --create-namespace \
  --version v24.3.0
```

### Expected Output
Confirm operator boot:
```text
NAME: gpu-operator
LAST DEPLOYED: Wed Jul 15 20:15:00 2026
NAMESPACE: gpu-operator
STATUS: deployed
```

### Verification
Check the status of operator daemons:
```bash
kubectl get pods -n gpu-operator
```

### Cleanup
Keep the GPU operator installed as it is required for downstream validation.

### Lessons
The GPU Operator uses DaemonSets matching Node Feature Discovery node labels to install GPU packages dynamically.

---

## Lab 3: Validate Device Plugin

### Objective
Confirm the NVIDIA Device Plugin is running and has successfully registered the node's GPU capabilities with the local Kubelet.

### Architecture
```text
NVIDIA Device Plugin -> Registers via UNIX Socket -> Reports Allocatable GPUs to Kubelet status
```

### Commands
Check the Device Plugin logs:
```bash
kubectl logs -n gpu-operator -l app=nvidia-device-plugin-daemonset --tail=50
```

### Expected Output
```text
2026-07-15T20:16:00Z INFO: Starting NVIDIA Device Plugin...
2026-07-15T20:16:01Z INFO: Registered device plugin for nvidia.com/gpu with Kubelet
```

### Verification
Examine node hardware properties:
```bash
kubectl describe node -l accelerator=nvidia-gpu | grep -A 5 Allocatable
```

### Cleanup
None (core infrastructure verification).

### Lessons
The Device Plugin uses gRPC to report hardware capacities. Kubelet holds this state in memory until the plugin restarts or disconnects.

---

## Lab 4: Run CUDA Workload

### Objective
Execute a matrix multiplication workload inside a CUDA container to verify computational execution.

### Architecture
```text
Workload Pod -> Container Runtime -> NVIDIA Container Toolkit -> Accesses GPU device files (/dev/nvidiactl)
```

### Commands
Deploy the verification job:
```bash
kubectl apply -f 03-workloads/gpu-test-deployment.yaml
```

### Expected Output
Workload execution logs:
```text
[CUDA Matrix Multiplication] - Starting...
GPU Device 0: "Tesla T4" with Compute Capability 7.5
MatrixA (1024x1024) * MatrixB (1024x1024)
Execution time: 4.12 ms. Success!
```

### Verification
```bash
kubectl logs -l app=gpu-test --tail=20
```

### Cleanup
```bash
kubectl delete -f 03-workloads/gpu-test-deployment.yaml
```

### Lessons
The container toolkit must successfully inject host-level CUDA runtimes (`libcuda.so`) into the container namespace during creation for workloads to compile correctly.

---

## Lab 5: Configure Time Slicing

### Objective
Configure GPU Time Slicing on EKS nodes to partition 1 physical GPU into 4 virtual devices.

### Architecture
```text
ClusterPolicy ConfigMap -> Sets Sharing Mode -> Device Plugin reports 4 nvidia.com/gpu devices per host GPU
```

### Commands
Apply the partition ConfigMap:
```bash
kubectl apply -f 02-platform/karpenter/karpenter-gpu-nodeclass.yaml
# Patch the ClusterPolicy to reference time-slicing
kubectl patch clusterpolicy default --type=merge -p '{"spec":{"devicePlugin":{"config":{"name":"time-slicing-config","default":"time-slicing-config"}}}}'
```

### Expected Output
Confirm capacity change:
```text
Capacity:
  nvidia.com/gpu: 4
Allocatable:
  nvidia.com/gpu: 4
```

### Verification
```bash
kubectl describe node -l accelerator=nvidia-gpu | grep nvidia.com/gpu
```

### Cleanup
Delete time-slicing patch if returning to single tenant mode.

### Lessons
Time-slicing exposes multiple logical device namespaces over a single GPU, bypassing compute limitations for low-tier tasks.

---

## Lab 6: Deploy 4 GPU Workloads

### Objective
Launch 4 concurrent applications targeting partitioned GPU capacities simultaneously.

### Architecture
```text
4 Pods (Request: nvidia.com/gpu: 1) -> Scheduled on a single physical node containing 4 virtual slices
```

### Commands
Deploy 4 replicated workloads:
```bash
kubectl apply -f 03-workloads/gpu-test-pod-workloads.yaml
```

### Expected Output
Observe scheduling status:
```text
NAME           READY   STATUS    RESTARTS   AGE
gpu-pod-1      1/1     Running   0          10s
gpu-pod-2      1/1     Running   0          10s
gpu-pod-3      1/1     Running   0          10s
gpu-pod-4      1/1     Running   0          10s
```

### Verification
Check node assignments (all 4 should report the same node name):
```bash
kubectl get pods -o wide -l app=gpu-load-test
```

### Cleanup
```bash
kubectl delete -f 03-workloads/gpu-test-pod-workloads.yaml
```

### Lessons
Using Time Slicing prevents Karpenter from launching multiple expensive compute instances, consolidating workloads into a single node.

---

## Lab 7: Validate Scheduling

### Objective
Confirm scheduling properties (taints and tolerations) enforce correct workload placement.

### Architecture
```text
CPU Pod -> Attempts to schedule on GPU Node -> Rejected by Taint (nvidia.com/gpu:NoSchedule)
```

### Commands
Deploy a CPU pod lacking tolerations:
```bash
kubectl apply -f 03-workloads/cpu-test-deployment.yaml
```

### Expected Output
Confirm the CPU pod schedules on standard CPU nodes:
```text
NAME           NODE
cpu-pod-xxxx   dev-system-node-xxx
```

### Verification
Ensure no CPU pod is assigned to a GPU node:
```bash
kubectl get pods -o wide | grep cpu-pod
```

### Cleanup
```bash
kubectl delete -f 03-workloads/cpu-test-deployment.yaml
```

### Lessons
Isolating compute spaces prevents CPU workloads from exhausting resources on GPU-specialized machines.

---

## Lab 8: Install DCGM Exporter

### Objective
Configure the NVIDIA Data Center GPU Manager (DCGM) exporter daemonset to expose hardware performance telemetry.

### Architecture
```text
DCGM Exporter -> Pulls driver API data -> Formats metrics -> Exposes port 9400
```

### Commands
Verify the DCGM exporter pod:
```bash
kubectl get pods -n gpu-operator -l app.kubernetes.io/name=nvidia-dcgm-exporter
```

### Expected Output
```text
NAME                                READY   STATUS    RESTARTS   AGE
nvidia-dcgm-exporter-xxxxx          1/1     Running   0          5m
```

### Verification
Query metrics endpoint:
```bash
kubectl exec -n gpu-operator daemonset/nvidia-dcgm-exporter -- curl -s localhost:9400/metrics | head -n 10
```

### Cleanup
None (Observability baseline verification).

### Lessons
The DCGM exporter communicates directly with driver instances via host mount directories, reporting exact device telemetry.

---

## Lab 9: Prometheus Integration

### Objective
Configure Prometheus to scrape telemetry targets exposed by the DCGM exporter service.

### Architecture
```text
Prometheus Scraper -> DCGM Service Endpoint -> Scrapes Port 9400 -> Stores metrics in TSDB
```

### Commands
Apply Prometheus monitoring stack:
```bash
kubectl apply -f 02-platform/monitoring/prometheus-grafana.yaml
```

### Expected Output
Prometheus configuration validation:
```text
service/prometheus-service created
deployment.apps/prometheus-deployment created
```

### Verification
Check Prometheus target list status:
```bash
kubectl logs -l app=prometheus --tail=50 | grep "Scrape target"
```

### Cleanup
Keep monitoring deployed for Lab 10.

### Lessons
Automating scrape configurations via ServiceMonitors ensures immediate integration when new nodes bootstrap.

---

## Lab 10: Grafana Dashboard

### Objective
Deploy Grafana and configure visualization dashboards for the EKS GPU platform.

### Architecture
```text
Grafana UI -> Queries Prometheus -> Renders SM Utilization & VRAM panels
```

### Commands
Expose Grafana port locally:
```bash
kubectl port-forward svc/grafana-service 3000:3000 &
```

### Expected Output
Browse `http://localhost:3000` (Access credentials: `admin / admin`).

### Verification
Confirm telemetry streams for `dcgm_fb_used` and `dcgm_sm_copy` in the dashboard panels.

### Cleanup
Terminate the background port-forward process:
```bash
kill $(jobs -p)
```

### Lessons
Dashboards must focus on hardware limit metrics (e.g. Throttle Reason) to diagnose performance degradation dynamically.

---

## Lab 11: Break GPU Operator Intentionally

### Objective
Simulate a production outage by breaking the GPU container runtime toolkit configuration.

### Architecture
```text
Inject Invalid Runtime Class -> Containerd restarts -> Toolkit fails -> GPU workloads remain in Pending
```

### Commands
Apply an invalid `ClusterPolicy` configuring a broken runtime binary:
```bash
kubectl patch clusterpolicy default --type=merge -p '{"spec":{"toolkit":{"env":[{"name":"RUNTIME_ARGS","value":"--invalid-arg"}]}}}'
```

### Expected Output
Validate container creation errors:
```text
Warning FailedCreatePodSandBox 2s kubelet Failed to create sandbox: rpc error: code = Unknown desc = failed to setup network: ...
```

### Verification
```bash
kubectl describe pod -n gpu-operator -l app=nvidia-toolkit-daemonset
```

### Lessons
A failure in the container runtime interface layer halts node execution immediately, preventing nodes from servicing any container runtimes.

---

## Lab 12: Recover ClusterPolicy

### Objective
Restore cluster operations by reverting runtime modifications and resolving container runtime configurations.

### Architecture
```text
Revert ClusterPolicy -> GPU Operator restarts daemonsets -> Resolves configuration -> Pods schedule
```

### Commands
Revert the ClusterPolicy patch:
```bash
kubectl patch clusterpolicy default --type=merge -p '{"spec":{"toolkit":{"env":[]}}}'
```

### Expected Output
Reconciliation loop completes successfully:
```text
2026-07-15T20:25:00Z INFO gpu-operator-controller ClusterPolicy reconciled successfully
```

### Verification
Verify that pods transition out of the `ContainerCreating` status:
```bash
kubectl get pods -A
```

### Lessons
Operators reconcile configuration drift automatically, but soft restarts of underlying daemons may still cause brief execution delays.

---

## Lab 13: Investigate Pending Pods

### Objective
Diagnose and resolve scheduling blockages for a pod requesting more GPU resources than are allocatable.

### Architecture
```text
Workload requests: nvidia.com/gpu: 8 -> Single node capacity: 1 -> Pod remains Pending (Unschedulable)
```

### Commands
Deploy a mismatched resource pod:
```bash
kubectl run large-gpu-workload --image=nvidia/cuda:12.0.0-base-ubuntu20.04 \
  --requests="nvidia.com/gpu=8" --restart=Never
```

### Expected Output
Investigate scheduling feedback:
```text
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  10s   default-scheduler  0/3 nodes are available: 3 Insufficient nvidia.com/gpu.
```

### Verification
```bash
kubectl describe pod large-gpu-workload
```

### Cleanup
```bash
kubectl delete pod large-gpu-workload
```

### Lessons
Kubernetes scheduler requires execution requests to be satisfiable on a single host. Compute pools cannot aggregate GPU requests across separate physical instances unless using distributed frameworks (like Ray or Volcano).

---

## Lab 14: Karpenter Troubleshooting

### Objective
Identify scheduling issues caused by applying incompatible instance selectors on Karpenter NodePool definitions.

### Architecture
```text
Pod requests GPU -> Karpenter evaluates NodePool constraints -> No instances match requirements -> Scale-up fails
```

### Commands
Apply a NodePool with an invalid instance constraint:
```bash
kubectl patch nodepool gpu-pool --type=json -p='[{"op": "replace", "path": "/spec/template/spec/requirements/2/values", "value": ["invalid-instance-type"]}]'
```
Trigger scale-up:
```bash
kubectl run trigger-pod --image=nvidia/cuda:12.0.0-base-ubuntu20.04 --requests="nvidia.com/gpu=1" --restart=Never
```

### Expected Output
Karpenter logs:
```text
2026-07-15T20:30:00Z ERROR karpenter.controller NodePool "gpu-pool" is unschedulable: no instance types match the requirements
```

### Verification
Confirm pod remains in `Pending` with no nodeclaim created:
```bash
kubectl get nodeclaims
```

### Cleanup
```bash
kubectl delete pod trigger-pod
kubectl apply -f 02-platform/karpenter/karpenter-gpu-nodepool.yaml
```

### Lessons
Always keep instance selectors broad or align them with cloud provider service lists. Enforcing rigid instance profiles halts platform horizontal scaling.

---

## Lab 15: GPU Metrics Investigation

### Objective
Simulate CUDA application execution while scraping and inspecting metric changes directly from the DCGM endpoint.

### Architecture
```text
CUDA application runs -> SM usage spikes -> DCGM exporter records load -> Prometheus tracks metric increase
```

### Commands
Deploy high compute simulation workload:
```bash
kubectl apply -f 03-workloads/gpu-test-deployment.yaml
```
Scrape SM utilization metrics from the exporter:
```bash
kubectl exec -n gpu-operator daemonset/nvidia-dcgm-exporter -- curl -s localhost:9400/metrics | grep DCGM_FI_DEV_GPU_UTIL
```

### Expected Output
```text
DCGM_FI_DEV_GPU_UTIL{gpu="0",UUID="GPU-xxxxx"} 98
```

### Verification
Confirm the value increases from `0` to near `100` during run phases.

### Cleanup
```bash
kubectl delete -f 03-workloads/gpu-test-deployment.yaml
```

### Lessons
Tracking SM utility indicators (`DCGM_FI_DEV_GPU_UTIL`) validates workload execution, distinguishing idle resources from executing platforms.
