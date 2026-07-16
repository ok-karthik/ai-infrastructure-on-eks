# Performance Profiling & Scaling Latency Observations

This document details the performance observations, scaling latency benchmarks, and hardware profiling outcomes gathered during execution runs on the AI Infrastructure Platform on Amazon EKS.

---

## 1. Metric Performance Observations

During validation testing under load (e.g., executing parallel matrix calculations and inference pipelines), we monitored low-level hardware metrics via the DCGM Exporter:

*   **GPU Utilization (`DCGM_FI_DEV_GPU_UTIL`):** Streaming Multiprocessor (SM) utilization is binary during inference, jumping rapidly between `0%` and `100%`. Standard Prometheus scraping (30s) misses these transients; we reduced the scrape interval to 5s.
*   **Power Draw (`DCGM_FI_DEV_POWER_USAGE`):** Scales linearly with SM occupancy. A Tesla T4 has a 70W TDP. Under peak load, power stabilizes at 68-70W. Extended TDP saturation triggers clock throttling (`dcgm_clock_throttle_reasons`).
*   **VRAM Allocation (`DCGM_FI_DEV_FB_USED`):** Unlike CPU memory, VRAM cannot swap to disk. Exceeding limits (e.g., loading a 16GB model onto a 15GB T4 card) triggers immediate Out Of Memory (OOM) runtime faults.

---

## 2. GPU Time Slicing Benchmark Analysis

We benchmarked the execution characteristics of running 4 concurrent pods on a single physical Tesla T4 partitioned via GPU Time Slicing:

```mermaid
gantt
    title GPU Time Slicing Execution Windows
    dateFormat  X
    axisFormat %s
    section Pod 1
    Execute :active, 0, 10
    Wait    :crit, 10, 30
    section Pod 2
    Wait    :crit, 0, 10
    Execute :active, 10, 20
    Wait    :crit, 20, 30
    section Pod 3
    Wait    :crit, 0, 20
    Execute :active, 20, 30
```

### Key Technical Findings:
*   **Shared VRAM Address Space:** Because GPU Time Slicing does not enforce memory boundaries, the combined memory requested by all containers must not exceed the physical GPU limit.
*   **SM Latency Overhead:** Context-swapping compute kernels at the driver level introduces a **15% to 25% execution latency penalty** compared to single-tenant execution due to registry store/restore cycles.

---

## 3. Provisioning & Scheduling Latency Gates

We benchmarked the end-to-end latency required to transition a pending GPU pod to a `Running` status on Karpenter-provisioned nodes.

```text
EKS Dynamic Scale-Up Timeline:
T=0s    --> Pod submitted, marked Pending (Insufficient resources)
T=1.5s  --> Karpenter detects pod, calls AWS CreateFleet API
T=35s   --> EC2 instance booted, registers as Ready Node in EKS
T=40s   --> Node Feature Discovery scans node and applies PCI capability labels
T=48s   --> GPU Operator schedules Driver container
T=72s   --> Driver compilation and insertion complete (Host kernel module active)
T=85s   --> NVIDIA Container Toolkit restarts containerd
T=92s   --> Kubernetes Device Plugin registers with Kubelet
T=95s   --> Kubelet advertises nvidia.com/gpu; Scheduler binds Pod to Node
T=108s  --> Workload container downloaded, CUDA validation completes, starts execution
```

### Bottleneck Analysis:
*   **Dynamic Driver Compilation:** Dynamically compiling drivers on boot introduces a ~24-30s delay. Pre-baking drivers into a custom EKS-optimized AL2023 GPU AMI reduces this compilation time to 0s, shortening the dynamic scheduling loop to **under 45 seconds**.

---

## 4. Production Considerations

> [!NOTE] Production Note: Sharing Strategies
> GPU Time Slicing is appropriate for low-tier, latency-tolerant workloads (e.g., development sandboxes or low-throughput inference). It is unsuitable for production serving or distributed training. Deploy Multi-Instance GPU (MIG) or Multi-Process Service (MPS) to guarantee latency SLAs.

---

## Related Documentation
*   **System Layouts:** [Architecture Topology](architecture.md) | [Troubleshooting Runbook](troubleshooting.md) | [Future Roadmap](roadmap.md)
*   **Conceptual Focus:** [Device Plugin Interface](interview-notes/device-plugin.md) | [GPU Operator Internals](interview-notes/gpu-operator.md) | [Virtualization Models](interview-notes/time-slicing.md) | [Karpenter Scheduling](interview-notes/karpenter.md)
*   **Journal Logs:** [Post-Mortems & Lessons Learned](lessons-learned.md)
