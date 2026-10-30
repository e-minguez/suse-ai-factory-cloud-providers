# 02: HA cluster with storage on evroc

Shape overview: [../README.md](../README.md). Status: not run end to end on evroc yet. `make test-catalog` checks the plan only.

## Prerequisites

- `evroc login`. It writes `~/.evroc/config.yaml`. The provider reads credentials, region and project from it, and `deploy.sh` stops if the file is missing. There is no API key in the tfvars.
- Optional `clusters/common-evroc.tfvars` with `region` (for example `"se-sto"`) and `project`. `null` uses the values of the login. Other shared settings go in `clusters/common-all.tfvars`: see [shared prerequisites](../../README.md#shared-prerequisites). Do not put them in the shape file.
- Application Collection credentials (`appco_username`, `appco_password`) are required by `suse-storage`.
- GPU quota for one L40S (counted in GPUs; a default project has one). The plan cannot see it; `provider_details.gpu_quota_request` shows the demand. Only zone `a` admits GPU VMs, and the plan checks it. See [GPUs](../../../docs/providers/evroc.md#gpus).
- A vCPU quota increase. Quota is organization-wide. The default is 20 vCPU, 160 GB memory and 3 public IPs. This shape needs more vCPU than the default:

  | Part | vCPU | Memory (GB) |
  |---|---|---|
  | Jumphost (`a1a.m`) | 4 | 16 |
  | 3 control planes (`a1a.m`) | 12 | 48 |
  | `general` pool, 2 x `a1a.m` | 8 | 32 |
  | `storage` pool, 3 x `a1a.m` | 12 | 48 |
  | Total, pass 2 | 36 | 144 |

  The GPU node is not counted in vCPU or memory. Public IPs: 2 (API VIP and jumphost). The plan fails when the peak footprint of this cluster exceeds the limit. Usage by other clusters is not checked, so a second cluster can pass the plan and be denied at apply. Ask evroc to raise the quota first. See [Quota](../../../docs/providers/evroc.md#quota).
- The profiles `a1a.m` and `gn-l40s.s` must be offered in your project. The plan fails if one is not.
- The storage disk is 500 GB per node (`disk_size_gb`). The disk size, not the profile, sets the Longhorn capacity per node.

## Steps

```bash
tools/multicluster/cluster.sh new --empty evroc ha
cp catalog/02-ha-storage/evroc/ha.tfvars.example clusters/ha/terraform.tfvars   # cp keeps the 600 mode of the existing file
$EDITOR clusters/ha/terraform.tfvars
tools/multicluster/cluster.sh cost ha      # estimate, needs Go
tools/multicluster/cluster.sh deploy ha
```

The deploy runs three passes; see [Passes](../../../docs/providers/evroc.md#passes).

1. Pass 1 builds the image: one build host per zone, each writes the image to a disk. Snapshots are zonal, so the image is built once for each zone in `zones` (here `a`, `b` and `c`).
2. Pass 2 makes a snapshot per zone and creates the nodes.
3. Pass 3 reclaims the build disks.

There is no serial console. Follow the build with `clusters/ha/build-logs.sh`. `deploy` shows the plan and asks for confirmation.

Variables in `ha.tfvars.example`: `cluster_name`, `components`, `control_plane_count`, `control_plane_instance_type`, `gpu_pools`, `worker_pools`, `suse_storage_nodes`. `zones` is not set, so the default `["a", "b", "c"]` applies. `ingress_domain` is optional and commented out.

Pool keys become hostnames `aif-ha-<pool>-NN`. `cp` is reserved and a worker pool cannot be named `gpu`.

### Zones

Control planes go round-robin over the zones: one in each of `a`, `b` and `c`. A pool lives in one zone. A pool without `zone` uses the first zone, `a`. So in the example the GPU, `general` and `storage` pools all run in zone `a`. `placement = "spread"` puts the nodes of the `storage` pool on separate hosts in that zone, but not in separate zones.

Variant, not tested: keep one storage replica in each zone. Use three storage pools pinned to `a`, `b` and `c`, and list all of them:

```hcl
worker_pools = {
  general   = { instance_type = "a1a.m", count = 2 }
  storage-a = { instance_type = "a1a.m", count = 1, disk_size_gb = 500, zone = "a" }
  storage-b = { instance_type = "a1a.m", count = 1, disk_size_gb = 500, zone = "b" }
  storage-c = { instance_type = "a1a.m", count = 1, disk_size_gb = 500, zone = "c" }
}

suse_storage_nodes = ["storage-a", "storage-b", "storage-c"]
```

## Verify

```bash
mkdir -p ~/.kube
clusters/ha/kubeconfig.sh --wait -o ~/.kube/aif-ha.yaml     # admin credential, mode 600, no overwrite without --force
export KUBECONFIG=~/.kube/aif-ha.yaml
kubectl get nodes                                 # 3 control plane, 1 gpu, 2 general, 3 storage; all Ready
kubectl get pods -A                               # all Running or Completed
kubectl get nodes -l node.longhorn.io/create-default-disk=true   # 3 nodes (the storage pool)
kubectl get storageclass                          # one default class: longhorn
terraform -chdir=clusters/ha output -raw next_steps   # Rancher URL, ssh, kubeconfig
```

`clusters/ha/kubeconfig.sh` prints to stdout without `-o`. The class name `longhorn` is the chart default; adjust if it differs.

The API (6443) and the ingress (80/443) share one public IP, the API VIP. The default hostnames are sslip.io names of that IP. With `ingress_domain`, create an A record `*.<domain>` to it. Nodes have no public IP. ICMP is blocked, so ping fails; probe TCP instead. See [Networking](../../../docs/providers/evroc.md#networking).

## Cost

Nine nodes (3 control plane, 1 GPU, 2 general, 3 storage), a jumphost, one public IP for the API VIP, a load balancer and snapshots in three zones. Run `tools/multicluster/cluster.sh cost ha` for an estimate. It prices VMs, disks and public IPs from a rate card (EUR, excluding VAT). The load balancer, snapshots and traffic are not included. Build hosts and build disks are shown as build only. It is not a quote. See [Cost estimate](../../../docs/providers/evroc.md#cost-estimate).

## Destroy

```bash
tools/multicluster/cluster.sh destroy ha
```

After a successful destroy, `deploy.sh` prints a leftovers check. It does not run it. Run it yourself. It uses the login of the `evroc` CLI:

```bash
tools/leftovers/evroc.sh aif-ha
```

It deletes nothing. It also lists snapshots and disks. Exit code 0 means nothing is left, 1 means something is left, 3 means the check was inconclusive. See [Leftover check](../../../docs/providers/evroc.md#leftover-check).

Quota is released asynchronously after a destroy. If a new deploy is denied right after, run it again.

To reuse the name `ha`, remove the old directory first: `cluster.sh new` refuses an existing one (`rm -rf clusters/ha`).

## Troubleshooting

See [examples/evroc/README.md](../../../examples/evroc/README.md#troubleshooting) and [docs/providers/evroc.md](../../../docs/providers/evroc.md).

- Plan fails with "vCPU / Memory / Public IP quota: this cluster needs N ...": the footprint exceeds the organization limit. Ask evroc for a quota increase; see Prerequisites.
- "Requested flavors not offered": the profile is not available. The error lists the profiles that are.
- `cannot deploy a GPU VM in zone "b"`: GPU VMs run in zone `a` only. Do not pin the GPU pool to another zone.
- `not enough quota ... nvidia.com/AD102GL_L40S` at apply: GPU quota is missing. Compare `provider_details.gpu_quota_request` with your allowance.
- Plan fails on `suse_storage_nodes`: fewer than three nodes would get disks.
- Longhorn PVC binds but the pod hangs in `ContainerCreating`: `systemctl status iscsi-prep.service iscsid` on the node.
