# 04: Management and GPU downstream with storage on Harvester

Shape overview: [../README.md](../README.md). Status: not run end to end on Harvester yet; the GPU cluster is untested (no GPU passthrough tested yet).
The `gpu` cluster adds three storage nodes (pool `storage`, SUSE Storage on the root disk) and two worker nodes.

## Prerequisites

- The shared prerequisites: [../../README.md#shared-prerequisites](../../README.md#shared-prerequisites).
  This includes `clusters/common-all.tfvars`. Harvester values go in `clusters/common-harvester.tfvars`
  (mode 600): optionally `harvester_kubeconfig_path` (else the kubeconfig comes from
  `KUBECONFIG`), `harvester_namespace`, `vpc_id` (`<namespace>/<network>`), `vpc_cidr` (the real subnet
  of that network) and `region` (a label, `"harvester"`). `harvester_kubecontext` is optional. These values
  are not in the cluster file.
- Harvester 1.8 or later with an existing namespace and an existing VM network (`vpc_id`). Creating networks is not part of the module.
- Two free static IPv4 addresses in `vpc_cidr` per cluster, outside the DHCP range, all distinct: `mgmt` uses `.40` and `.41`, `gpu` uses `.42` and `.43`.
- Harvester downloads the openSUSE Leap cloud image from `buildhost_image_url` unless `jumphost_image` names an existing image in the namespace. The cluster needs outbound access for that download.
- Application Collection credentials (`appco_username`, `appco_password`) are required by local-path-provisioner.
- The GPU cluster needs PCI passthrough enabled on Harvester (`pcidevices-controller`) and the GPU bound to passthrough. The GPU path is not tested on Harvester yet, so the `gpu` cluster is untested.
- Totals for `gpu`: 3 control planes (8 vCPU, 32 GiB), 2 workers and 3 storage nodes (8 vCPU, 16 GiB), one GPU node (30 vCPU, 240 GiB, one `nvidia.com/GA102GL_A10` device).

## Steps

Run from the repo root, in order.

1. Create, edit and deploy `mgmt`.

   ```bash
   tools/multicluster/cluster.sh new --empty harvester mgmt
   cp catalog/04-mgmt-gpu-storage/harvester/mgmt.tfvars.example clusters/mgmt/terraform.tfvars
   $EDITOR clusters/mgmt/terraform.tfvars
   tools/multicluster/cluster.sh deploy mgmt
   ```

2. Create, edit and deploy `gpu`.

   ```bash
   tools/multicluster/cluster.sh new --empty harvester gpu
   cp catalog/04-mgmt-gpu-storage/harvester/gpu.tfvars.example clusters/gpu/terraform.tfvars
   $EDITOR clusters/gpu/terraform.tfvars
   tools/multicluster/cluster.sh deploy gpu
   ```


Import `gpu` into the management Rancher (`--bootstrap` once; see [tools/multicluster/README.md](../../../tools/multicluster/README.md)):

```bash
tools/multicluster/cluster.sh register --bootstrap mgmt gpu
```

`register` checks that the `mgmt` `ingress_cidrs` include the `gpu` egress address. On Harvester the VLAN network has no NAT gateway, so `egress_ips` may be empty and `register` continues; `ingress_cidrs` are not enforced (no security groups on the VLAN).

## Verify

```bash
tools/multicluster/cluster.sh list
terraform -chdir=clusters/mgmt output -raw rancher_url
clusters/gpu/kubeconfig.sh --wait -o ~/.kube/aif-gpu.yaml
KUBECONFIG=~/.kube/aif-gpu.yaml kubectl get nodes
KUBECONFIG=~/.kube/aif-gpu.yaml kubectl get pods -n gpu-operator
```

The cluster `aif-gpu` is listed and `Active` in Rancher; the GPU node reports `nvidia.com/gpu` (untested on Harvester).

## Destroy

Destroy the downstream cluster first.

```bash
tools/multicluster/cluster.sh destroy gpu
tools/multicluster/cluster.sh destroy mgmt
```

Delete the imported cluster in the Rancher UI and remove `gpu` from `clusters/.register/mgmt/downstream.list`; delete `clusters/.register/mgmt/` before a new `mgmt`. After a successful destroy, `deploy.sh` prints a leftovers check for `tools/leftovers/harvester.sh`. It does not run it; run it yourself with your kubeconfig for the Harvester cluster. It deletes nothing.

## Troubleshooting

- Plan fails on `api_vip` or `ingress_vip`: an address is outside `vpc_cidr`, two addresses are equal, or an address is already in use (both clusters use distinct pairs). The plan does not check DHCP leases.
- Plan fails on the image, the network or the GPU device: `jumphost_image`, `vpc_id` or the PCI device does not exist or is not enabled for passthrough.
- Nodes stay Pending: Harvester has no free capacity for the plans. The plan does not read host capacity.
- Platform notes and the first-deploy checklist: [docs/providers/harvester.md](../../../docs/providers/harvester.md).
