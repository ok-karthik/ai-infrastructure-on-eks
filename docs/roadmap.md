# Platform Engineering Future Roadmap

This document outlines the proposed architecture additions, scaling optimizations, and software integrations planned to transition the AI Infrastructure Platform on Amazon EKS into a production-tier LLM training and serving engine.

---

## 1. High-Density Inference Serving

*   **Multi-Instance GPU (MIG) Partitioning:** Transition from GPU Time Slicing to physical MIG partitioning on A100/H100 hardware to enforce hardware boundary limits on SM and VRAM allocations.
*   **vLLM & Triton Inference Server:** Deploy serving runtimes optimized for PagedAttention and concurrent model execution.
*   **KServe Orchestration:** Manage autoscaling and scale-to-zero configurations based on incoming request queues.

---

## 2. Distributed Training at Scale

*   **AWS EFA (Elastic Fabric Adapter):** Configure Amazon EC2 instances supporting EFA interfaces inside Karpenter NodePool specs to enable inter-node network bypass.
*   **NCCL (NVIDIA Collective Communications Library) Optimizations:** Tune host kernel parameters using GPUDirect RDMA to bypass CPU memory, enabling direct GPU-to-NIC memory transfers.

---

## 3. Advanced Job Scheduling & Orchestration

*   **Volcano Batch Scheduler:** Deploy Volcano for gang scheduling (ensuring training jobs only start if all pods in the job can be provisioned concurrently) and queue management.
*   **Ray Cluster Integration (KubeRay):** Integrate KubeRay to manage distributed Ray clusters on top of Karpenter-provisioned EKS nodes.

---

## 4. Platform Control & AI Gateway

*   **AI Gateway Proxy (LiteLLM/Envoy):** Deploy an API Gateway in front of serving layers to centralize API rate limiting, routing across heterogeneous endpoints, and usage auditing.

---

## Related Documentation
*   **System Layouts:** [Architecture Topology](architecture.md) | [Troubleshooting Runbook](troubleshooting.md) | [Performance Profiling](performance.md)
*   **Conceptual Focus:** [Device Plugin Interface](interview-notes/device-plugin.md) | [GPU Operator Internals](interview-notes/gpu-operator.md) | [Virtualization Models](interview-notes/time-slicing.md) | [Karpenter Scheduling](interview-notes/karpenter.md)
*   **Journal Logs:** [Post-Mortems & Lessons Learned](lessons-learned.md)
