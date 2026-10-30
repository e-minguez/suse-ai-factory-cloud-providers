# 01: Inference in a box on evroc

Shape overview: [../README.md](../README.md). Status: verified end to end on 2026-10-30 (se-sto, `gn-l40s.s` control plane, aif 2.3.0, RKE2 v1.35.6): GPU allocatable (L40S, 46068 MiB, driver 615.71.09), Rancher and the AI Factory operator up, local-path volume bound, a second deploy plans no changes, leftovers check clean. The control plane needed one manual recovery during the first boot; see [rke2-server restart loop](#rke2-server-restart-loop-after-the-first-boot).

## Prerequisites

- `evroc login`. It writes `~/.evroc/config.yaml`. The provider reads credentials, region and project from it, and `deploy.sh` stops if the file is missing. There is no API key in the tfvars.
- Optional `clusters/common-evroc.tfvars` with `region` (for example `"se-sto"`) and `project`. `null` uses the values of the login. Other shared settings go in `clusters/common-all.tfvars`: see [shared prerequisites](../../README.md#shared-prerequisites). Do not put them in the shape file.
- Application Collection credentials (`appco_username`, `appco_password`) are required by local-path-provisioner.
- GPU quota for one L40S. The quota is per GPU model and counted in GPUs. A default project has one L40S. The plan cannot see this quota; `provider_details.gpu_quota_request` shows the demand. See [GPUs](../../../docs/providers/evroc.md#gpus) and [Quota](../../../docs/providers/evroc.md#quota).
- Only zone `a` admits GPU VMs. The example sets `zones = ["a"]`, and the plan checks it. This also means the image is built once.
- The profile `gn-l40s.s` must be offered in your project. The plan fails if it is not.
- The example node has 15 vCPU, 190 GB RAM and 1x L40S 48 GB. The GPU is passthrough.
- Footprint against the quota: 4 vCPU and 16 GB memory (the jumphost only; GPU VMs draw no vCPU or memory quota), 2 public IPs (API VIP and jumphost) and 1 L40S. This fits a default project.
- The control plane disk is 500 GB (`control_plane_disk_size_gb`). It holds the models and the local-path volumes.

## Steps

```bash
tools/multicluster/cluster.sh new --empty evroc box
cp catalog/01-inference-in-a-box/evroc/box.tfvars.example clusters/box/terraform.tfvars   # cp keeps the 600 mode of the existing file
$EDITOR clusters/box/terraform.tfvars
tools/multicluster/cluster.sh cost box     # estimate, needs Go
tools/multicluster/cluster.sh deploy box
```

The deploy runs three passes; see [Passes](../../../docs/providers/evroc.md#passes).

1. Pass 1 builds the image on a build host and writes it to a disk.
2. Pass 2 makes the snapshot and creates the nodes.
3. Pass 3 reclaims the build disks.

There is no serial console. Follow the build with `clusters/box/build-logs.sh`. `deploy` shows the plan and asks for confirmation.

Variables in `box.tfvars.example`: `cluster_name`, `components`, `zones`, `control_plane_count`, `control_plane_instance_type`, `control_plane_disk_size_gb`. `ingress_domain` is optional and commented out.

## Verify

```bash
mkdir -p ~/.kube
clusters/box/kubeconfig.sh --wait -o ~/.kube/aif-box.yaml    # admin credential, mode 600, no overwrite without --force
export KUBECONFIG=~/.kube/aif-box.yaml
kubectl get nodes                                  # one node, Ready
kubectl get pods -A                                # all Running or Completed
kubectl describe node | grep nvidia.com/gpu        # GPU capacity 1
terraform -chdir=clusters/box output -raw next_steps   # Rancher URL, ssh, kubeconfig
```

`clusters/box/kubeconfig.sh` prints to stdout without `-o`. The GPU operator can take several minutes to show the GPU. The module uses an experimental precompiled SLES 16.1 GPU driver by default; see [workarounds](../../../docs/workarounds.md).

Rancher and the Kubernetes API share the one public IP (the API VIP). The default hostnames are sslip.io names of that IP. With `ingress_domain`, create an A record `*.<domain>` to it. Nodes have no public IP. ICMP is blocked, so ping fails; probe TCP instead. See [Networking](../../../docs/providers/evroc.md#networking) and [API VIP](../../../docs/providers/evroc.md#api-vip).

## Cost

One GPU node, one jumphost, one public IP for the API VIP, a load balancer and a snapshot. Run `tools/multicluster/cluster.sh cost box` for an estimate. It prices VMs, disks and public IPs from a rate card (EUR, excluding VAT). The load balancer, snapshots and traffic are not included. Build hosts and build disks are shown as build only. It is not a quote. See [Cost estimate](../../../docs/providers/evroc.md#cost-estimate).

## Grow

With a GPU flavor on the control plane, `control_plane_count = 3` keeps all three nodes in zone `a` (the plan requires `zones = ["a"]`) and needs GPU quota for three L40S. For HA across zones, use the [shape 02](../../02-ha-storage/evroc/README.md) layout: non-GPU control planes and a `gpu_pools` entry.

## Destroy

```bash
tools/multicluster/cluster.sh destroy box
```

After a successful destroy, `deploy.sh` prints a leftovers check. It does not run it. Run it yourself. It uses the login of the `evroc` CLI:

```bash
tools/leftovers/evroc.sh aif-box
```

It deletes nothing. It also lists snapshots and disks. Exit code 0 means nothing is left, 1 means something is left, 3 means the check was inconclusive. See [Leftover check](../../../docs/providers/evroc.md#leftover-check).

Quota is released asynchronously after a destroy. If a new deploy is denied right after, run it again.

To reuse the name `box`, remove the old directory first: `cluster.sh new` refuses an existing one (`rm -rf clusters/box`).

## Troubleshooting

See [examples/evroc/README.md](../../../examples/evroc/README.md#troubleshooting) and [docs/providers/evroc.md](../../../docs/providers/evroc.md).

- "Requested flavors not offered": the profile is not available. The error lists the profiles that are.
- `cannot deploy a GPU VM in zone "b"`: GPU VMs run in zone `a` only. Keep `zones = ["a"]`.
- `not enough quota ... nvidia.com/AD102GL_L40S` at apply: GPU quota is missing. Compare `provider_details.gpu_quota_request` with your allowance and ask evroc to raise it.
- Nothing answers on a running VM: there is no console. See [There is no console](../../../docs/providers/evroc.md#there-is-no-console).
- GPU not visible: see [GPUs](../../../docs/providers/evroc.md#gpus).

### rke2-server restart loop after the first boot

Symptom: `kubectl` returns `Error from server (Timeout)` while `kubectl version`
still answers. On the node, `systemctl is-active rke2-server` shows
`activating` and the journal repeats every few seconds:

```
level=fatal msg="Error: preparing server: failed to bootstrap cluster data: failed to reconcile with local datastore: context deadline exceeded"
```

Cause: during the first boot the node pulls several GB of images onto the same
disk as etcd. In the test run one etcd disk sync took 1.6 s, rke2 lost its
lease (`leaderelection lost for rke2-etcd`) and exited. etcd keeps running
after rke2 exits, but its log output is no longer read, so it blocks and
stops answering ([rancher/rke2#11056](https://github.com/rancher/rke2/issues/11056)).
Every restart of rke2 then times out against it. It does not recover by
itself. With one control plane the whole cluster is down; with three, the
other nodes keep it up.

Recovery, as root on the node (`su -`); the etcd data is kept:

```bash
systemctl stop rke2-server
rke2-killall.sh            # path differs per image: find / -name rke2-killall.sh 2>/dev/null
systemctl start rke2-server
```

Without the script, stop the service and run `pkill -9 -f containerd-shim`.
The node is `Ready` again within minutes; the GPU operator redeploys its pods
and the GPU is allocatable a few minutes later. See
[workarounds](../../../docs/workarounds.md).
