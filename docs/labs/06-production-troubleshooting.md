# Lab 6: Production Troubleshooting & Chaos Testing

## Objective
Simulate container runtime failures on GPU nodes, diagnose the resulting scheduling issues, and restore the EKS node to a healthy operating state.

---

## Failure Simulation

To verify platform resilience, we simulate a container runtime failure on a GPU node:
1.  **Inject Fault:** Apply a malformed configuration value to the Container Toolkit configuration inside the `ClusterPolicy` Custom Resource.
2.  **Expected Failure:** Containerd fails to initialize the NVIDIA runtime class, causing pods scheduled on the node to remain stuck in `ContainerCreating`.

---

## Execution Commands

*   **Purpose:** Inject a runtime configuration fault.
    *   **Command:**
        ```bash
        kubectl patch clusterpolicy default --type=merge -p '{"spec":{"toolkit":{"env":[{"name":"RUNTIME_ARGS","value":"--invalid-arg"}]}}}'
        ```
    *   **Expected Result:** Container Toolkit pods restart and fail validation checks.
    *   **Validation:** Verify pod status: `kubectl get pods -n gpu-operator -l app=nvidia-toolkit-daemonset`

*   **Purpose:** Diagnose the container scheduling failure.
    *   **Command:**
        ```bash
        kubectl describe pod -l app=gpu-test
        ```
    *   **Expected Result:** Pod remains stuck in `ContainerCreating` or `CreateContainerConfigError`.
    *   **Validation:** Check event logs for errors like `failed to setup custom containerd runtime hook`.

---

## Recovery Steps

*   **Purpose:** Revert the Container Toolkit configuration fault.
    *   **Command:**
        ```bash
        kubectl patch clusterpolicy default --type=merge -p '{"spec":{"toolkit":{"env":[]}}}'
        ```
    *   **Expected Result:** ClusterPolicy reconciles successfully.
    *   **Validation:** Verify that the `ClusterPolicy` status returns to `Ready`.

*   **Purpose:** Verify pod recovery.
    *   **Command:**
        ```bash
        kubectl rollout restart deployment/gpu-test
        ```
    *   **Expected Result:** Old pods terminate, and new pods start successfully.
    *   **Validation:** Verify that pods transition to a `Running` status.

---

> [!NOTE] Production Note: Validation Gates
> Dynamic config changes directly affect host OCI runtimes. Ensure all `ClusterPolicy` updates are verified in a staging environment before deploying to production.

---

## Operational Notes
*   **Runtime Dependency:** The Container Toolkit must be registered in containerd (`/etc/containerd/config.toml`) and containerd restarted before the Device Plugin can successfully allocate devices.
*   **Event Log Diagnostics:** When debugging runtime errors, check host syslog and containerd logs (`journalctl -u containerd`) rather than just Kubernetes pod logs.
*   **Fail-Safe Node Tainting:** Implement automation to automatically taint a node as `NoSchedule` if the Container Toolkit daemonset fails validation, preventing Kubelet from routing workloads to that node.

---

## Related Documentation
*   **Core Systems:** [Architecture Topology](../architecture.md) | [Troubleshooting Runbook](../troubleshooting.md) | [Performance Profiling](../performance.md)
*   **Detailed Labs:** [01: Provisioning](01-gpu-node-provisioning.md) | [02: GPU Operator](02-gpu-operator.md) | [03: Device Plugin](03-device-plugin.md) | [04: Time-Slicing](04-time-slicing.md) | [05: Observability](05-dcgm-observability.md)
*   **Journal Logs:** [Post-Mortems & Lessons Learned](../lessons-learned.md)
