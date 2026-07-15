# Platform Engineering Future Roadmap

This document outlines the proposed architecture additions, scaling optimizations, and software integrations planned to transition the AI Infrastructure Platform on Amazon EKS into a production-tier LLM training and serving engine.

---

## 1. High-Density Inference Serving

Currently, the platform partitions compute resources using software-level GPU Time-Slicing. To support high-throughput, low-latency production inference pipelines, we plan the following additions:

### Multi-Instance GPU (MIG) Partitioning
*   **Target:** Migrate from software time-slicing to physical MIG partitioning on A100/H100/A30 enterprise hardware.
*   **Outcome:** Enforce strict hardware boundary limits on both Streaming Multiprocessors (SMs) and VRAM allocations, providing true multi-tenant security and zero context-switching latency penalties.

### Serving Framework Integration (vLLM / Triton)
*   **Target:** Deploy serving runtimes like vLLM (for PagedAttention optimizations) and NVIDIA Triton Inference Server (for model concurrent execution and dynamic batching).
*   **Deployment:** Orchestrate serving layers under **KServe** to manage autoscaling from zero (scale-to-zero) based on incoming request queues.

---

## 2. Distributed Training at Scale

To expand the platform's capacity from running simple single-node validation containers to supporting large-scale distributed model training (e.g. training over multiple nodes), we plan to incorporate:

### AWS EFA (Elastic Fabric Adapter) Integration
*   **Target:** Configure Amazon EC2 instances supporting EFA interfaces inside the Karpenter NodePool specs.
*   **Outcome:** Enable bypass networking for node-to-node communications, drastically reducing networking latency over high-performance inter-node fabrics.

### NCCL (NVIDIA Collective Communications Library) Optimizations
*   **Target:** Tune host kernel parameters to optimize communication patterns across GPUs (AllReduce, AllGather) using GPUDirect RDMA.
*   **Outcome:** Bypass CPU host memory completely, allowing direct GPU-to-network-card memory transfers during training loops.

---

## 3. Advanced Job Scheduling & Orchestration

Standard Kubernetes scheduling operates on a first-come, first-served basis, which leads to resource starvation during concurrent ML training workloads.

### Volcano Batch Scheduler
*   **Target:** Deploy the Volcano scheduler alongside the default Kubernetes scheduler.
*   **Outcome:** Implement advanced scheduling paradigms:
    -   **Gang Scheduling:** Ensure distributed training jobs only start if all pods in the job can be provisioned concurrently, preventing deadlocks where half the pods occupy GPUs while waiting indefinitely for the remaining resources.
    -   **Queue Management:** Establish fair-share queue limits across different developer namespaces.

### Ray Cluster Integration (KubeRay)
*   **Target:** Integrate KubeRay operators to orchestrate dynamic Ray Clusters on top of Karpenter-provisioned EKS nodes.
*   **Outcome:** Provide developers with unified Python endpoints to distribute computation across dynamic pools of workers.

---

## 4. Platform Control & AI Gateway

### LLM Gateway / AI Proxy
*   **Target:** Deploy an API Gateway layer (like Envoy or LiteLLM) in front of model serving pods.
*   **Outcome:** Centralize API rate-limiting, coordinate routing across heterogeneous model endpoints, encrypt telemetry data, and audit API call access credentials in one central control plane.
