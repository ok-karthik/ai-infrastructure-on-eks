# Systems Architecture: Kubernetes Device Plugin Interface

This document contains deep-dive interview preparation notes, systems design, and conceptual guides on the Kubernetes Device Plugin framework, with a specific focus on the NVIDIA Device Plugin.

---

## Systems Architecture & Registration Flow

The Device Plugin framework allows external hardware vendors to register custom resource types with the local `kubelet` process without modifying the core Kubernetes codebase.

```mermaid
sequenceDiagram
    autonumber
    participant Host as Host OS / GPU Drivers
    participant DP as NVIDIA Device Plugin DaemonSet
    participant Kubelet as Kubelet Daemon
    participant APIServer as Kubernetes API Server

    Host->>DP: Expose hardware files under /dev/nvidia*
    DP->>Kubelet: Connect to Kubelet UNIX socket & invoke Register()
    Kubelet-->>DP: Confirm registration & open gRPC connection
    DP->>Kubelet: Stream device IDs & health status via ListAndWatch()
    Kubelet->>APIServer: Update Node Status Allocatable (nvidia.com/gpu: 1)
```

---

## Core Lifecycle Methods

The device plugin implements a gRPC service defined by the following protobuf contract:

```protobuf
service DevicePlugin {
    rpc GetDevicePluginOptions(Empty) returns (DevicePluginOptions) {}
    rpc ListAndWatch(Empty) returns (stream ListAndWatchResponse) {}
    rpc Allocate(AllocateRequest) returns (AllocateResponse) {}
    rpc PreStartContainer(PreStartContainerRequest) returns (PreStartContainerResponse) {}
}
```

### 1. `Register()`
*   **Trigger:** Executed by the Device Plugin during initialization.
*   **Mechanism:** The plugin connects to Kubelet's control socket at `/var/lib/kubelet/device-plugins/kubelet.sock` and calls the `Register` gRPC endpoint, sending:
    -   Its UNIX socket name (e.g., `/var/lib/kubelet/device-plugins/nvidia-gpu.sock`).
    -   The API version.
    -   The resource name it exposes (e.g., `nvidia.com/gpu`).

### 2. `ListAndWatch()`
*   **Trigger:** Executed immediately after successful registration.
*   **Mechanism:** Opens a long-running gRPC streaming connection. The Device Plugin scans the host hardware (using `NVML` or `DCGM`) and streams the list of active device UUIDs and their health states (Healthy/Unhealthy) to Kubelet.
*   **Self-Healing:** If a physical GPU fails (e.g., thermal event or ECC memory threshold exceeded), the plugin updates the status to `Unhealthy`. Kubelet removes it from the allocatable pool, preventing new pods from landing on the broken card.

### 3. `Allocate()`
*   **Trigger:** Executed by Kubelet's **Device Manager** during the pod scheduling phase (specifically, container runtime configuration).
*   **Mechanism:** Kubelet passes the requested device IDs to the plugin. The plugin returns an `AllocateResponse` which details:
    -   Host mount paths (`/usr/lib64/...`) that need binding into the container.
    -   Device nodes (`/dev/nvidia0`, `/dev/nvidiactl`, `/dev/nvidia-uvm`) to expose.
    -   Runtime environment variables (e.g. `NVIDIA_VISIBLE_DEVICES="GPU-xxxx"`).

---

## Kubelet Device Manager Internals

The Kubelet Device Manager maintains the allocation state of hardware across the host.
*   **State Database:** It stores active allocations in a local memory database (`/var/lib/kubelet/device-plugins/kubelet_internal_checkpoint`).
*   **Container Binding:** When Kubelet boots a container that requests `nvidia.com/gpu`, it reads this checkpoint file, identifies which GPU UUID was assigned, calls the plugin's `Allocate()` method for that UUID, and configures the OCI container configuration payload before invoking the Container Runtime Interface (CRI).

---

## Tradeoffs & Best Practices

| Area | Challenge | Best Practice |
|---|---|---|
| **Resource Isolation** | Standard device plugins do not limit VRAM consumption. A container can allocate the entire physical memory, causing adjacent workloads to crash with OOM errors. | Implement time-slicing configurations or shift to Multi-Instance GPU (MIG) for hard physical partitioning. |
| **Driver Updates** | Upgrading host-level drivers requires restarting the Device Plugin, causing brief scheduling disruptions. | Implement node taints and drain the node before initiating driver upgrades. |
| **Node Join Latency** | Instantiating drivers and compiling packages at boot time slows down Karpenter scale-up events. | Pre-bake the NVIDIA driver stack directly into a custom AMI. |

---

## Common Interview Questions & Answers

### Q1: How does Kubernetes map a request for `nvidia.com/gpu: 1` to a physical device?
**Answer:** The request is modeled as an **Extended Resource**. 
1. The scheduler identifies a node advertising `nvidia.com/gpu` capacity (reported by Kubelet via `ListAndWatch`).
2. Once the pod is assigned to a node, Kubelet's Device Manager allocates a device UUID.
3. Kubelet calls `Allocate()` on the NVIDIA Device Plugin, which translates the UUID into host-level character device paths (e.g. `/dev/nvidia0`).
4. Kubelet invokes the CRI runtime (containerd), injecting these paths into the OCI specifications.

### Q2: What happens if the Device Plugin pod crashes? Are existing workloads impacted?
**Answer:** Existing workloads continue running unaffected. The container runtime has already configured the mounts and cgroups for those processes. However, new pods requiring GPUs cannot be scheduled or initialized on that node because Kubelet will stop advertising the resource once `ListAndWatch` connection drops.

### Q3: Why are GPU resources treated as integers and not decimals? (Can you request `nvidia.com/gpu: 0.5`?)
**Answer:** By default, Kubernetes Extended Resources do not support fractional allocations. Kubelet tracks capacity as integer counts. To support sharing, you must configure device plugin wrappers (like GPU Time-Slicing) which simulate fractional allocation by presenting multiple virtual integer devices (e.g., exposing 1 physical device as 4 virtual devices, each mapped to 1 integer resource).
