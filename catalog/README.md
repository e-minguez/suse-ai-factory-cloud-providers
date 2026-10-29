# Cluster shapes catalog

Ready-made cluster shapes for SUSE AI Factory: from one GPU node that runs
everything to a platform of four clusters with central monitoring and
security. Each shape has:

- a `README.md` that explains the shape: what you get, diagrams, components and
  why, sizing, limits and variants. This part does not depend on the provider.
- one folder per provider with a step-by-step guide and one
  `<cluster>.tfvars.example` per cluster.

Every cluster in a shape is a [`tools/multicluster`](../tools/multicluster/README.md)
cluster on the provider's example root (`examples/<provider>`). The catalog adds
no Terraform code: a shape is a set of variable files plus the steps to deploy
them.

## Shapes

| Shape | Clusters | Nodes | Components | Providers |
|---|---|---|---|---|
| [01 Inference in a box](01-inference-in-a-box/README.md) | 1 | 1 control plane on a GPU plan | rancher, aif-operator, gpu-operator, local-path-provisioner | [vultr](01-inference-in-a-box/vultr/README.md) |
| [02 HA cluster with storage](02-ha-storage/README.md) | 1 | 3 control plane, GPU pool, worker pool, 3 storage nodes | rancher, aif-operator, gpu-operator, suse-storage | [vultr](02-ha-storage/vultr/README.md) |
| [03 Management and GPU downstream](03-mgmt-gpu/README.md) | 2 | mgmt: 3 control plane<br>gpu: 3 control plane + GPU pool | mgmt: rancher, aif-operator, local-path-provisioner<br>gpu: cert-manager, gpu-operator, local-path-provisioner | [vultr](03-mgmt-gpu/vultr/README.md) |
| [04 Management and GPU downstream with storage](04-mgmt-gpu-storage/README.md) | 2 | mgmt: 3 control plane<br>gpu: 3 control plane + GPU pool + worker pool + 3 storage nodes | mgmt: rancher, aif-operator, local-path-provisioner<br>gpu: cert-manager, gpu-operator, suse-storage | [vultr](04-mgmt-gpu-storage/vultr/README.md) |
| [05 Platform](05-platform/README.md) | 4 | mgmt, obs, sec, gpu: 3 control plane each<br>gpu also has a GPU pool | mgmt: rancher, aif-operator, local-path-provisioner, observability-plugin, observability-agent, security-downstream<br>obs: observability-server, local-path-provisioner, security-downstream<br>sec: security-management, local-path-provisioner, observability-agent<br>gpu: cert-manager, gpu-operator, local-path-provisioner, security-downstream, observability-agent | [vultr](05-platform/vultr/README.md) |

Start with 01 to try AI Factory on one machine. Use 03 or later when
management and GPU workloads must be separate, for example to add GPU clusters
in other regions later.

## Shared prerequisites

Every shape needs the same tools and shared values.

**Tools:** Terraform 1.16.5 or later, `jq`, `ssh`, `curl`, `kubectl`; Go for the
optional cost estimate (`cluster.sh cost`); `uuidgen` and `openssl` for shape 05
(shared tokens). The provider guide lists what else it needs.

**Shared values.** `cluster.sh` layers the variable files, later wins:
`common-all.tfvars` at the repo root, then `clusters/common-all.tfvars`,
`clusters/common-<provider>.tfvars` and the cluster's own
`clusters/<name>/terraform.tfvars`. Put everything that is the same for all
clusters in the shared files, so the cluster files only hold the shape:

```bash
mkdir -p clusters
cp common-all.tfvars.example clusters/common-all.tfvars
chmod 600 clusters/common-all.tfvars
$EDITOR clusters/common-all.tfvars
```

`clusters/common-all.tfvars` holds the values every provider declares:
`admin_cidrs`, `ssh_authorized_keys` ([docs/ssh-keys.md](../docs/ssh-keys.md)),
`root_password_hash` and `node_user_password_hash` (`openssl passwd -6`,
different passwords), the registry credentials (`appco_*`,
`suse_registry_*`, `nvidia_api_key`) and `aif_release`. Shape 05 adds
`security_join_token` and `observability_bootstrap_token` here, so that all
its clusters use the same values.

`clusters/common-<provider>.tfvars` holds the provider credentials and
location. For vultr:

```hcl
# clusters/common-vultr.tfvars (mode 600)
vultr_api_key = "REPLACE_WITH_YOUR_API_KEY"
region        = "ams"
```

The files under `clusters/` are gitignored and hold secrets: keep them at mode
600 and never commit them. The same applies to the Terraform state in each
cluster directory ([docs/security.md](../docs/security.md)).

**Creating a cluster from a shape.** `cluster.sh new --empty` creates an empty
`terraform.tfvars` with mode 600; copying the shape file over it keeps that
mode:

```bash
tools/multicluster/cluster.sh new --empty vultr <name>
cp catalog/<shape>/vultr/<name>.tfvars.example clusters/<name>/terraform.tfvars
$EDITOR clusters/<name>/terraform.tfvars
tools/multicluster/cluster.sh cost <name>      # optional estimate
tools/multicluster/cluster.sh deploy <name>
```

## Common limits

These apply to every shape and are not implemented today:

- Worker and GPU pools have no Kubernetes taints or custom node labels. A
  dedicated storage or GPU pool also runs other workloads unless you add taints
  or node selectors yourself after the deploy.
- SUSE Storage (Longhorn) uses the root disk of its nodes. There is no separate
  data volume per node.
- `components` is an image input: changing it builds a new image and replaces
  every node of that cluster.

## Provider notes

### Vultr: one VPC range for all clusters

`examples/vultr` does not expose `vpc_cidr`, so every cluster in a shape with
more than one cluster (03, 04, 05) uses the default `10.20.0.0/20` in its own
VPC. Nothing in the repository depends on the ranges being different: the
clusters talk to each other only through public load balancer addresses and DNS
names, and the VPC range is used only inside one cluster. Vultr accepts
several VPCs with the same subnet in one region (checked 2026-10-29).

## Testing

`make test-catalog` plans every `catalog/*/<provider>/*.tfvars.example` file
in a clean copy of `examples/<provider>` (`examples/.catalog-<provider>`) with
mocked providers (`examples/<provider>/tests/catalog.tftest.hcl`), so a change to a variable
validation that breaks a shape fails CI. A new plan used by a shape must be
added to the mocked availability list in that test file. The test file sets
dummy values that the shape files leave open, for example
`observability_license_key = "DUMMY-LICENSE"`: test variables override the shape
file. The shapes are
deployed end to end by hand. Each provider guide has a `Status` line, which is
updated after an end-to-end run.
