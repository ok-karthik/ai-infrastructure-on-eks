# Hands-On Labs

A guided path through the platform, from an empty AWS account to a shared GPU
with telemetry flowing.

Each lab below has a full write-up under [`labs/`](labs/). This page is the index
and the quick command reference; the linked guides carry the explanation, the
failure modes, and the trade-offs.

---

## Prerequisites

The cluster must be up (`make apply`) and your kubeconfig pointed at it
(`make kubeconfig`). Confirm with:

```bash
make status
```

---

## The path

| # | Lab | What you learn | Guide |
|---|---|---|---|
| 1 | GPU node provisioning | How Karpenter turns a Pending pod into a Spot GPU instance | [01](labs/01-gpu-node-provisioning.md) |
| 2 | GPU Operator | What makes a GPU schedulable, and why the driver is disabled here | [02](labs/02-gpu-operator.md) |
| 3 | Device plugin | The kubelet gRPC contract: `Register`, `ListAndWatch`, `Allocate` | [03](labs/03-device-plugin.md) |
| 4 | Time slicing | Sharing one card across pods, and what that does *not* isolate | [04](labs/04-time-slicing.md) |
| 5 | DCGM observability | Exporting GPU telemetry and scraping it correctly | [05](labs/05-dcgm-observability.md) |
| 6 | Production troubleshooting | Breaking it deliberately and diagnosing from symptoms | [06](labs/06-production-troubleshooting.md) |

---

## Quick command reference

### Provisioning

```bash
# CPU-only scale-out — validates the Karpenter path without GPU spend
kubectl apply -f 03-workloads/cpu-test-deployment.yaml
kubectl get nodeclaims -w

# GPU scale-out
make gpu-test
```

Watch the sequence: pods go `Pending`, a NodeClaim appears, a node registers,
NFD labels it, the device plugin registers, pods bind.

### GPU capacity

```bash
# What the scheduler believes is available
kubectl get nodes -l accelerator=nvidia-gpu \
  -o custom-columns=NODE:.metadata.name,CAPACITY:.status.capacity.'nvidia\.com/gpu',ALLOCATABLE:.status.allocatable.'nvidia\.com/gpu'

# Operand health
kubectl get pods -n gpu-operator
kubectl get clusterpolicy default -o jsonpath='{.status.state}'
```

### Time slicing

```bash
kubectl apply -f 03-workloads/gpu-test-pod-workloads.yaml
kubectl wait --for=condition=Ready pod -l app=gpu-load-test --timeout=10m

# The assertion: all 4 pods, one node
kubectl get pods -l app=gpu-load-test -o wide
```

### Scheduling isolation

The GPU NodePool is tainted `nvidia.com/gpu=true:NoSchedule`, so CPU workloads
must never land on a GPU node:

```bash
kubectl apply -f 03-workloads/cpu-test-deployment.yaml
kubectl get pods -l app=cpu-test -o wide
```

Cross-check the `NODE` column against
`kubectl get nodes -l accelerator=nvidia-gpu` — there should be no overlap. If a
CPU pod does land on a GPU node, the taint or the toleration is wrong, and you
are paying GPU prices to run a pause container.

### Telemetry

```bash
kubectl get pods -n gpu-operator -l app=nvidia-dcgm-exporter

# Scrape the exporter directly
kubectl exec -n gpu-operator ds/nvidia-dcgm-exporter -- \
  curl -s localhost:9400/metrics | grep DCGM_FI_DEV_GPU_UTIL

# Prometheus — check the dcgm-exporter job under Status > Targets
kubectl port-forward -n monitoring svc/prometheus-service 9090:9090

# Grafana — credentials are in 02-platform/monitoring/prometheus-grafana.yaml
kubectl port-forward -n monitoring svc/grafana-service 3000:3000
```

---

## Failure-injection exercises

Diagnosing from symptoms is the skill worth practising. Each of these has a
recovery step; run them on a cluster you are willing to break.

### 1. Request more GPUs than exist

```bash
kubectl run large-job --image=nvidia/cuda:12.2.0-base-ubuntu22.04 \
  --overrides='{"spec":{"tolerations":[{"key":"nvidia.com/gpu","operator":"Exists","effect":"NoSchedule"}],"containers":[{"name":"large-job","image":"nvidia/cuda:12.2.0-base-ubuntu22.04","resources":{"limits":{"nvidia.com/gpu":8}}}]}}' \
  --restart=Never

kubectl describe pod large-job | tail -20
```

The pod stays `Pending`. The instructive part is the event text: Karpenter
reports it cannot find an instance type satisfying the request, which is a
different failure from "no capacity right now".

```bash
kubectl delete pod large-job
```

### 2. Break Karpenter's instance-type requirement

```bash
kubectl patch nodepool gpu-pool --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/requirements/2/values","value":["invalid-family"]}]'

kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --tail=50
```

Recover:

```bash
kubectl apply -f 02-platform/karpenter/karpenter-gpu-nodepool.yaml
```

### 3. Break the time-slicing config

```bash
kubectl patch clusterpolicy default --type=merge \
  -p '{"spec":{"devicePlugin":{"config":{"default":"does-not-exist"}}}}'

kubectl rollout status ds/nvidia-device-plugin-daemonset -n gpu-operator --timeout=60s
kubectl logs -n gpu-operator ds/nvidia-device-plugin-daemonset --tail=30
```

The plugin fails to start on a config key that is not in the ConfigMap, GPU
capacity disappears from the node, and running GPU pods are evicted. Recover by
letting Terraform reassert the correct value:

```bash
terraform -chdir=01-infrastructure apply -target=module.bootstrap
```

> [!NOTE]
> Guides for this stack often suggest injecting a bad `RUNTIME_ARGS` into
> `spec.toolkit` to simulate a container-runtime outage. That does nothing here:
> the toolkit is supplied by the EKS NVIDIA-optimized AMI and the operator's
> toolkit operand is disabled, so there is no DaemonSet to break. See
> [Lab 02](labs/02-gpu-operator.md) for why.

---

## Cleanup

```bash
kubectl delete -f 03-workloads/cpu-test-deployment.yaml --ignore-not-found
make gpu-clean
```

Karpenter consolidates the empty GPU node about a minute later. Confirm it is
gone before walking away:

```bash
kubectl get nodes -l accelerator=nvidia-gpu
```

---

## Related documentation

- **Reference:** [Architecture](architecture.md) · [Troubleshooting runbook](troubleshooting.md) · [Performance](performance.md) · [Roadmap](roadmap.md)
- **Journal:** [Lessons learned](lessons-learned.md)
