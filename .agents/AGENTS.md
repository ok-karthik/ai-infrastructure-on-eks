# AI Agent Guidelines (AGENTS.md)

Rules, context, and commands for AI coding assistants working on this repository.
`CLAUDE.md` at the repo root points here; this file is the single source of truth.

---

## 1. What this repository is

A Terraform-provisioned EKS platform for GPU workloads. Karpenter provisions Spot
GPU nodes on demand, the NVIDIA GPU Operator makes the hardware schedulable, time
slicing shares one card across pods, and DCGM exports telemetry to Prometheus.

It is a portfolio and learning project, so **the explanatory comments are part of
the deliverable**, not incidental.

```text
01-infrastructure/        Terraform root module
├── 01-network/           VPC, 3 private + 2 public subnets, NAT, discovery tags
└── 02-eks/               Control plane, managed node group, addons, IAM, access entries
02-platform/              Child module: Helm releases (Argo CD, Karpenter, GPU Operator)
├── karpenter/            NodePool + EC2NodeClass YAML (CPU pool and GPU pool)
└── monitoring/           Prometheus + Grafana in the `monitoring` namespace
03-workloads/             CUDA load generator, time-slicing verification, Argo CD Application
docs/                     Architecture, labs/, interview-notes/, runbooks
Makefile                  Operational entrypoint
```

`02-platform` is consumed as a child module by `01-infrastructure` (as
`module.bootstrap`) and inherits the `helm` provider from the root. Run Terraform
from `01-infrastructure`, never from `02-platform`.

---

## 2. Non-obvious constraints

Read these before changing the corresponding area. Each was a real bug or a
deliberate trade-off, and the reasoning is documented at the code site too.

1. **Do not enable the GPU Operator's driver or toolkit operands.** The GPU
   `EC2NodeClass` uses the EKS NVIDIA-optimized AL2023 AMI, which already ships
   both. Enabling them gives two owners for one kernel module and containerd
   config; the driver DaemonSet crash-loops while `nvidia-smi` works on the host.
   Controlled by `gpu_driver_managed_by_operator` (default `false`).

2. **Time slicing is configured through the Helm chart, not a separate ConfigMap.**
   The device plugin reads its config at startup, so a separately-applied
   ConfigMap creates an ordering race. The chart owns both the ConfigMap and the
   `ClusterPolicy` reference. Change slice count via `gpu_time_slicing_replicas`.

3. **Never use a `#` comment inside a backslash-continued shell block in the
   Makefile.** The shell treats everything after `#` to the next real newline as a
   comment, and since `make` joins the whole recipe into one logical line, every
   remaining step is silently skipped. This previously made `apply-all` and
   `destroy-all` no-op after their first module. Use separate `$(MAKE)` targets.

4. **`aws_eks_node_group` uses `node_group_name_prefix`, not `node_group_name`.**
   The resource has `create_before_destroy = true`, and node group names must be
   unique per cluster, so a fixed name fails with a conflict on every replacing
   change.

5. **Scrape DCGM per pod, never through the Service.** `dcgm-exporter` is a
   DaemonSet; a `static_config` aimed at the Service VIP load balances to one
   arbitrary GPU node per scrape. Use `kubernetes_sd_configs` with `role: pod`.

6. **Karpenter finalizers deadlock `terraform destroy`.** The destroy-time
   provisioner in `02-platform/main.tf` deletes the CRs and strips finalizers
   before the controller goes away. Do not remove it.

7. **The Karpenter YAML manifests hardcode the cluster name.** `role:` and the
   `karpenter.sh/discovery` tag values in `02-platform/karpenter/*.yaml` embed
   `dev-eks-cluster` literally. They stay as plain YAML so Argo CD can adopt them
   later. If `var.cluster_name` changes, update those files in the same commit.

8. **Pin every external artifact.** Helm chart versions are variables in
   `02-platform/variables.tf`. The AWS Load Balancer Controller IAM policy is
   fetched at a release tag, not `main` — tracking `main` means upstream changes
   silently become IAM grants in the account.

---

## 3. Rules for changes

1. **Keep the explanatory comments.** The verbose "why it's needed / what happens
   without it" comments in the `.tf` files are intentional teaching material. Do
   not strip them when refactoring. Extend them when you add something non-obvious.
2. **Never state a metric, benchmark, or timing as measured unless it was.**
   `docs/performance.md` separates *expected characteristics* from a *measured
   results* table that is intentionally blank. Put unverified numbers in the
   former, never the latter. This applies to any claim of what was tested.
3. **Docs must match code.** If you change a manifest path, a command, a chart
   version, or a namespace, grep `docs/` and `README.md` for it in the same change.
4. **Private subnets for compute.** Nodes go in `module.network.private_subnet_ids`.
   Only load balancers and NAT belong in public subnets.
5. **Spot by default.** Both the managed node group and every Karpenter NodePool
   use Spot to keep this affordable.
6. **No static credentials.** Use EKS Pod Identity — this cluster has no IRSA OIDC
   provider and does not use the `aws-auth` ConfigMap. Never commit AWS keys or
   real passwords.
7. **Scope IAM.** New AWS permissions should be constrained by
   `aws:ResourceTag`/`aws:RequestTag` on the cluster ownership tag, or by ARN.
   `Resource = "*"` needs a comment justifying why the API supports nothing better.
8. **Never commit vendored upstream charts.** Reference charts by repository and
   pinned version.
9. **Watch cost.** GPU Spot nodes and the NAT Gateway are the expensive parts. Do
   not raise NodePool limits, disable consolidation, or add always-on GPU capacity
   without saying so explicitly.

---

## 4. Validation

Run before considering any change complete:

```bash
make fmt-check      # terraform fmt across both module trees
make validate       # terraform validate
make lint           # tflint --recursive (must be clean, not just non-fatal)
```

For Kubernetes manifests, at minimum confirm they parse:

```bash
python3 -c "import yaml,sys; list(yaml.safe_load_all(open(sys.argv[1])))" <file>
```

CI (`.github/workflows/ci.yml`) runs the same checks on push and pull request.
Never commit Terraform that fails `validate`, and never leave a new tflint
warning behind.

Note that `terraform validate` does not contact AWS, so it will not catch an
invalid IAM action name or a non-existent EKS version. Verify those against AWS
documentation or the API.

---

## 5. Common commands

```bash
make help           # all targets
make init           # terraform init
make plan           # execution plan
make apply          # full apply, then updates kubeconfig
make apply-all      # module by module: network -> eks -> platform (for debugging)

make kubeconfig     # point kubectl at the cluster
make status         # nodes, GPU capacity, NodeClaims, operator pods
make gpu-test       # deploy CUDA load generator, watch Karpenter provision
make gpu-clean      # remove GPU workloads

make destroy        # tear everything down
make destroy-all    # module by module, reverse order
```

Override configuration inline: `make apply REGION=us-west-2 CLUSTER_NAME=foo`.

---

## 6. Things to be careful about

- **`terraform destroy` failing partway leaves billable resources.** A stranded
  NAT Gateway or GPU node is the most likely way this project costs real money.
  `make destroy` prints a verification command; surface it to the user.
- **Do not run `helm install/uninstall` against releases Terraform manages.** They
  will fight over ownership.
- **The Argo CD server is disabled by default** (`argocd_enable_server = false`)
  so the install fits a single `t3.small`. The application controller still
  reconciles; there is simply no UI or `argocd` CLI endpoint.
- **A fresh AWS account often has a zero GPU Spot quota,** which presents as
  Karpenter reporting insufficient capacity forever rather than as a clear error.
