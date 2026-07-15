# Performance Profiling & Scaling Latency Observations

This document details the performance observations, scaling latency benchmarks, and hardware profiling outcomes gathered during execution runs on the AI Infrastructure Platform on Amazon EKS.

---

## 1. Metric Performance Observations

During validation testing under load (e.g. executing parallel matrix calculations and inference simulation pipelines), we monitored low-level hardware metrics via DCGM and tracked their behavioral thresholds:

### GPU Utilization (`DCGM_FI_DEV_GPU_UTIL`)
*   **Observations:** GPU Streaming Multiprocessor (SM) utilization is highly binary during short inference tasks. It jumps rapidly from `0%` to `100%` and immediately falls back. 
*   **Platform Note:** Traditional Kubernetes metrics scrapers (like metrics-server) collect data every 15-30 seconds, which completely misses these transient GPU utilization spikes. We implemented high-resolution (5-second) scraping inside Prometheus to prevent metric smoothing.

### Power Draw (`DCGM_FI_DEV_POWER_USAGE`)
*   **Observations:** Core power consumption scales linearly with SM occupancy. A standard Tesla T4 has a Thermal Design Power (TDP) limit of 70 Watts. Under peak workloads, we observed power draw stabilizing at 68-70W.
*   **Throttling:** When power draw hits TDP limits for extended periods, the GPU driver triggers power capping throttling (`dcgm_clock_throttle_reasons`), dropping core clock speeds to maintain thermal constraints.

### Frame Buffer Memory (VRAM)
*   **Observations:** Unlike CPU memory, VRAM cannot swap to disk when exhausted. If a model allocation exceeds physical limits (e.g. allocating 16GB on a 15GB T4 card), the CUDA application crashes immediately with an `Out Of Memory` (OOM) error.

---

## 2. GPU Time-Slicing Benchmark Analysis

We benchmarked the scheduling and execution characteristics of running 4 concurrent pods on a single physical Tesla T4 partitioned via software Time-Slicing:

```mermaid
gantt
    title GPU Time-Slicing Execution Windows
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
1.  **VRAM Fragmentation:** Since Time-Slicing does not provide VRAM boundaries, the sum of the memory requested by all running containers must not exceed the physical limit of the GPU. If three containers occupy 4GB each (12GB total), the fourth container will fail if it requests more than 3GB.
2.  **SM Latency Overhead:** Because execution is round-robin context-swapped at the driver level, we observed a **15% to 25% execution latency penalty** for deep learning workloads running concurrently compared to single-tenant executions. This latency corresponds directly to the driver overhead of loading and saving GPU register states during context rotations.

---

## 3. Provisioning & Scheduling Latency Gates

We benchmarked the end-to-end latency required to transition a pending GPU pod to a `Running` status on Karpenter-provisioned nodes.

```text
EKS Dynamic Scale-Up Timeline:
T=0s    --> Pod submitted, marked Pending (Insufficient resources)
T=1.5s  --> Karpenter detects pod, calls AWS EC2 CreateFleet API
T=35s   --> EC2 instance booted, registers as Ready Node in EKS
T=40s   --> NFD scans node and applies PCI capability labels
T=48s   --> GPU Operator schedules Driver container
T=72s   --> Driver compilation and insertion complete (Host kernel module active)
T=85s   --> Container Toolkit restarts containerd
T=92s   --> Device Plugin registers with Kubelet
T=95s   --> Kubelet advertises nvidia.com/gpu; Scheduler binds Pod to Node
T=108s  --> Workload container downloaded, CUDA validation completes, starts execution
```

### Bottleneck Analysis:
*   **Kernel Compilation Gate:** The single largest contributor to boot-up latency is dynamic driver module compilation (taking ~24-30 seconds). By transitioning to pre-baked node AMIs (using the EKS-optimized AL2023 GPU image), we reduced this step to 0 seconds, bringing the end-to-end scheduling latency down to **under 45 seconds**.

---

## 4. Platform Engineering Lessons Learned

> [!NOTE] Production Note: Sharing Strategies
> Through benchmarking, we validated that GPU Time-Slicing is highly appropriate for lightweight, latency-tolerant services (e.g. development sandboxes or low-throughput inference endpoints). It is entirely unsuitable for high-throughput production Serving or distributed training runs, where hardware-isolated options (MIG) or compute consolidation proxies (MPS) must be deployed to guarantee latency SLAs.
