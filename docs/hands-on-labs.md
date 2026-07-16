# Hands-On Infrastructure & Operations Labs

This index lists the 15 sequential labs implemented to validate capacity scaling, model virtualization, hardware observability, and chaos recovery configurations.

---

## Lab 1: Dynamic GPU Node Provisioning (Karpenter)
*   **Target Guide:** For full systems details, see [Lab 1: GPU Node Provisioning](labs/01-gpu-node-provisioning.md).
*   **Purpose:** Deploy the Karpenter autoscaling manifests.
    *   **Command:**
        ```bash
        kubectl apply -f 02-platform/karpenter/
        ```
    *   **Expected Result:** NodePool and EC2NodeClass configuration models registered.
    *   **Validation:** Verify resources: `kubectl get nodepools,ec2nodeclasses`
*   **Purpose:** Trigger dynamic scale-up by requesting GPU resources.
    *   **Command:**
        ```bash
        kubectl apply -f 03-workloads/gpu-test-pod-workloads.yaml
        ```
    *   **Expected Result:** Karpenter provisions a `g4dn.xlarge` instance.
    *   **Validation:** Monitor joining node status: `kubectl get nodes -l accelerator=nvidia-gpu -w`

---

## Lab 2: Deploy the GPU Operator
*   **Target Guide:** See [Lab 2: GPU Operator](labs/02-gpu-operator.md).
*   **Purpose:** Install the GPU Operator via Helm.
    *   **Command:**
        ```bash
        helm install gpu-operator nvidia/gpu-operator -n gpu-operator --create-namespace --version v24.3.0
        ```
    *   **Expected Result:** Operator components deploy to EKS.
    *   **Validation:** Check reconciliation status: `kubectl get clusterpolicy default`

---

## Lab 3: Validate the Kubernetes Device Plugin
*   **Target Guide:** See [Lab 3: Device Plugin](labs/03-device-plugin.md).
*   **Purpose:** Verify Device Plugin gRPC registration with Kubelet.
    *   **Command:**
        ```bash
        kubectl logs -n gpu-operator -l app=nvidia-device-plugin-daemonset --tail=50
        ```
    *   **Expected Result:** Logs indicating registration connection success.
    *   **Validation:** Verify allocatable capacity: `kubectl describe node -l accelerator=nvidia-gpu | grep nvidia.com/gpu`

---

## Lab 4: Run CUDA Validation Workload
*   **Purpose:** Run a validation workload container executing matrix multiplications.
    *   **Command:**
        ```bash
        kubectl apply -f 03-workloads/gpu-test-deployment.yaml
        ```
    *   **Expected Result:** The job schedules on the GPU node and prints computation logs.
    *   **Validation:** Read execution log stdout: `kubectl logs -l app=gpu-test --tail=20`

---

## Lab 5: Configure GPU Time Slicing
*   **Target Guide:** See [Lab 4: GPU Time Slicing](labs/04-time-slicing.md).
*   **Purpose:** Apply Time Slicing configuration templates.
    *   **Command:**
        ```bash
        kubectl apply -f 02-platform/karpenter/karpenter-gpu-nodeclass.yaml
        kubectl patch clusterpolicy default --type=merge -p '{"spec":{"devicePlugin":{"config":{"name":"device-plugin-config","default":"time-slicing-config"}}}}'
        ```
    *   **Expected Result:** GPU Operator updates node capacities.
    *   **Validation:** Verify replicated node capacity (e.g. 4 virtual devices): `kubectl describe node | grep nvidia.com/gpu`

---

## Lab 6: Deploy 4 Replicated GPU Pods
*   **Purpose:** Schedule 4 pods requesting 1 GPU unit each.
    *   **Command:**
        ```bash
        kubectl apply -f 03-workloads/gpu-test-pod-workloads.yaml
        ```
    *   **Expected Result:** All 4 pods schedule concurrently on a single physical node.
    *   **Validation:** Check node assignments: `kubectl get pods -o wide -l app=gpu-load-test`

---

## Lab 7: Verify Workload Scheduling Isolation
*   **Purpose:** Deploy a standard CPU pod without GPU tolerations.
    *   **Command:**
        ```bash
        kubectl apply -f 03-workloads/cpu-test-deployment.yaml
        ```
    *   **Expected Result:** The CPU pod is scheduled on standard system node instances, bypassing the GPU node.
    *   **Validation:** Check node labels on the selected host: `kubectl get pods -o wide | grep cpu-pod`

---

## Lab 8: Deploy DCGM Exporter
*   **Target Guide:** See [Lab 5: GPU Observability](labs/05-dcgm-observability.md).
*   **Purpose:** Verify that the DCGM Exporter daemonset is executing.
    *   **Command:**
        ```bash
        kubectl get pods -n gpu-operator -l app.kubernetes.io/name=nvidia-dcgm-exporter
        ```
    *   **Expected Result:** DCGM Exporter pods listed as `Running`.
    *   **Validation:** Query metrics locally: `kubectl exec -n gpu-operator daemonset/nvidia-dcgm-exporter -- curl -s localhost:9400/metrics | head -n 10`

---

## Lab 9: Deploy Prometheus Scraper Channels
*   **Purpose:** Install Prometheus configurations to scrape exporter targets.
    *   **Command:**
        ```bash
        kubectl apply -f 02-platform/monitoring/prometheus-grafana.yaml
        ```
    *   **Expected Result:** Scraper deployments initialized.
    *   **Validation:** Port-forward and check active targets: `kubectl port-forward svc/prometheus-service 9090:9090` (Verify target: `dcgm-exporter`)

---

## Lab 10: Deploy Grafana Dashboards
*   **Purpose:** Access the Grafana UI.
    *   **Command:**
        ```bash
        kubectl port-forward svc/grafana-service 3000:3000
        ```
    *   **Expected Result:** Grafana port exposed locally on port `3000` (Access: `admin / admin`).
    *   **Validation:** Confirm the GPU performance dashboard displays metric streams.

---

## Lab 11: Inject Container Runtime Outages (Chaos Testing)
*   **Target Guide:** See [Lab 6: Production Troubleshooting](labs/06-production-troubleshooting.md).
*   **Purpose:** Inject a broken argument into the container toolkit configuration.
    *   **Command:**
        ```bash
        kubectl patch clusterpolicy default --type=merge -p '{"spec":{"toolkit":{"env":[{"name":"RUNTIME_ARGS","value":"--invalid-arg"}]}}}'
        ```
    *   **Expected Result:** Nodes stop running new containers, throwing runtime errors.
    *   **Validation:** Check toolkit events: `kubectl describe pod -n gpu-operator -l app=nvidia-toolkit-daemonset`

---

## Lab 12: Recover Container Runtime Configuration
*   **Purpose:** Revert the container runtime patch.
    *   **Command:**
        ```bash
        kubectl patch clusterpolicy default --type=merge -p '{"spec":{"toolkit":{"env":[]}}}'
        ```
    *   **Expected Result:** ClusterPolicy reconciles successfully.
    *   **Validation:** Check that pods transition back to a `Running` status.

---

## Lab 13: Troubleshoot Mismatched Resource Requests
*   **Purpose:** Deploy a pod requesting more GPU resources than are physically available (e.g. requesting 8 GPUs on a 1-GPU host).
    *   **Command:**
        ```bash
        kubectl run large-job --image=nvidia/cuda:12.0.0-base-ubuntu20.04 --requests="nvidia.com/gpu=8" --restart=Never
        ```
    *   **Expected Result:** Pod remains stuck in `Pending` state.
    *   **Validation:** Check events for scheduling feedback: `kubectl describe pod large-job`

---

## Lab 14: Troubleshoot Karpenter Node Selector Mismatches
*   **Purpose:** Configure an invalid requirement on the Karpenter NodePool.
    *   **Command:**
        ```bash
        kubectl patch nodepool gpu-pool --type=json -p='[{"op": "replace", "path": "/spec/template/spec/requirements/2/values", "value": ["invalid-family"]}]'
        ```
    *   **Expected Result:** Scaling requests fail.
    *   **Validation:** Verify Karpenter errors: `kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter`

---

## Lab 15: Perform Live GPU Telemetry Scrapes
*   **Purpose:** Run a high-load simulation job and scrape GPU utilization.
    *   **Command:**
        ```bash
        kubectl apply -f 03-workloads/gpu-test-deployment.yaml
        ```
    *   **Expected Result:** Metric values increase under computation.
    *   **Validation:** Query the exporter endpoint directly: `kubectl exec -n gpu-operator daemonset/nvidia-dcgm-exporter -- curl -s localhost:9400/metrics | grep DCGM_FI_DEV_GPU_UTIL`

---

## Related Documentation
*   **Systems Guides:** [Architecture Deep-Dive](architecture.md) | [Performance Observations](performance.md) | [Roadmap Future Enhancements](roadmap.md)
*   **Detailed Labs:** [01: Provisioning](labs/01-gpu-node-provisioning.md) | [02: GPU Operator](labs/02-gpu-operator.md) | [03: Device Plugin](labs/03-device-plugin.md) | [04: Time-Slicing](labs/04-time-slicing.md) | [05: Observability](labs/05-dcgm-observability.md) | [06: Troubleshooting](labs/06-production-troubleshooting.md)
*   **Journal Logs:** [Post-Mortems & Lessons Learned](lessons-learned.md)
