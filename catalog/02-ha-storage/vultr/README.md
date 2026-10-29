# 02: HA cluster with storage on Vultr

Shape overview: [../README.md](../README.md). Status: not yet verified end to end.

## Prerequisites

- Shared credentials and settings in `clusters/common-all.tfvars` and `clusters/common-vultr.tfvars`: see [shared prerequisites](../../README.md#shared-prerequisites). Do not put them in the shape file.
- Application Collection credentials (`appco_username`, `appco_password`) are required by `suse-storage`.
- A GPU plan in stock in your region. The example plan `vcg-a40-24c-120g-48vram` is a
  passthrough plan with a verified driver. Plan fails and names the pool when a plan is
  not in stock. This also covers `vc2-6c-16gb` and `vx1-g-4c-16g-240s` (the storage
  plan has a 240 GB disk, which sets the Longhorn capacity per node). Check one region:

  ```bash
  curl -s -H "Authorization: Bearer $VULTR_API_KEY" \
    "https://api.vultr.com/v2/regions/$REGION/availability" \
    | jq -r '.available_plans[]' | grep -E '^vcg-'
  ```

  Check all regions: `VULTR_API_KEY=... tools/vultr/passthrough-stock.sh`.
  Stock varies by region. Set `region` in `common-vultr.tfvars` (default `ams`).
- Only passthrough GPU plans work; see [Cloud GPU](../../../docs/providers/vultr.md#cloud-gpu).

## Steps

```bash
tools/multicluster/cluster.sh new --empty vultr ha
cp catalog/02-ha-storage/vultr/ha.tfvars.example clusters/ha/terraform.tfvars   # cp keeps the 600 mode of the existing file
$EDITOR clusters/ha/terraform.tfvars
tools/multicluster/cluster.sh cost ha      # estimate, needs Go
tools/multicluster/cluster.sh deploy ha
```

The deploy runs two passes and builds the image on the jumphost. `deploy` shows the plan and asks for confirmation.

Variables in `ha.tfvars.example`: `cluster_name`, `components`, `control_plane_count`, `control_plane_instance_type`, `gpu_pools`, `worker_pools`, `suse_storage_nodes`. `ingress_domain` is optional and commented out.

Pool keys become hostnames `aif-ha-<pool>-NN`. `cp` is reserved and a worker pool cannot be named `gpu`.

## Verify

```bash
mkdir -p ~/.kube
clusters/ha/kubeconfig.sh -o ~/.kube/aif-ha.yaml     # admin credential, mode 600, no overwrite without --force
export KUBECONFIG=~/.kube/aif-ha.yaml
kubectl get nodes                                 # 3 control plane, 1 gpu, 2 general, 3 storage; all Ready
kubectl get pods -A                               # all Running or Completed
kubectl get nodes -l node.longhorn.io/create-default-disk=true   # 3 nodes (the storage pool)
kubectl get storageclass                          # one default class: longhorn
terraform -chdir=clusters/ha output -raw next_steps   # Rancher URL, ssh, kubeconfig
```

`clusters/ha/kubeconfig.sh` prints to stdout without `-o`. The class name `longhorn` is the chart default; adjust if it differs.

## Cost

Nine nodes (3 control plane, 1 GPU, 2 general, 3 storage), a jumphost, two load balancers, a NAT gateway and a snapshot. Run `tools/multicluster/cluster.sh cost ha` for an estimate. It is not a quote.

## Destroy

```bash
tools/multicluster/cluster.sh destroy ha
```

After a successful destroy, `deploy.sh` prints a leftovers check. It does not run it. Run it yourself after you export the API key:

```bash
export VULTR_API_KEY=...
tools/leftovers/vultr.sh aif-ha
```

It deletes nothing. Expect `0 live, 0 unknown`.

To reuse the name `ha`, remove the old directory first: `cluster.sh new` refuses an existing one (`rm -rf clusters/ha`).

## Troubleshooting

See [examples/vultr/README.md](../../../examples/vultr/README.md#troubleshooting) and [docs/providers/vultr.md](../../../docs/providers/vultr.md).

- "Plans not available in region": no stock, or a missing `vultr_api_key`.
- Plan fails on `suse_storage_nodes`: fewer than three nodes would get disks.
- Longhorn PVC binds but the pod hangs in `ContainerCreating`: `systemctl status iscsi-prep.service iscsid` on the node.
