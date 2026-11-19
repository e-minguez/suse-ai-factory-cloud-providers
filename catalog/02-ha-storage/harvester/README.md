# 02: HA cluster with storage on Harvester

Shape overview: [../README.md](../README.md). Status: not run end to end on Harvester yet.

## Prerequisites

- The shared prerequisites: [../../README.md#shared-prerequisites](../../README.md#shared-prerequisites).
  This includes `clusters/common-all.tfvars`. Harvester values go in `clusters/common-harvester.tfvars`
  (mode 600): optionally `harvester_kubeconfig_path` (else the kubeconfig comes from
  `KUBECONFIG`), `harvester_namespace`, `vpc_id` (`<namespace>/<network>`), `vpc_cidr` (the real subnet
  of that network) and `region` (a label, `"harvester"`). `harvester_kubecontext` is optional. These values
  are not in the cluster file.
- Harvester 1.8 or later with an existing namespace and an existing VM network (`vpc_id`). Creating networks is not part of the module.
- Two free static IPv4 addresses in `vpc_cidr`, outside the DHCP range: `api_vip` and `ingress_vip`. The example uses `.40` and `.41`.
- Harvester downloads the openSUSE Leap cloud image from `buildhost_image_url` unless `jumphost_image` names an existing image in the namespace. The cluster needs outbound access for that download.
- Application Collection credentials (`appco_username`, `appco_password`) are required by local-path-provisioner.
- A GPU node needs PCI passthrough enabled on Harvester (`pcidevices-controller`) and the GPU bound to passthrough. The GPU path is not tested on Harvester yet (no GPU passthrough test so far), so the GPU pool is untested.
- Totals: 3 control planes (8 vCPU, 32 GiB), 2 general and 3 storage nodes (8 vCPU, 16 GiB), one GPU node (30 vCPU, 240 GiB, one `nvidia.com/GA102GL_A10` device).

## Steps

```bash
tools/multicluster/cluster.sh new --empty harvester ha
cp catalog/02-ha-storage/harvester/ha.tfvars.example clusters/ha/terraform.tfvars
$EDITOR clusters/ha/terraform.tfvars
tools/multicluster/cluster.sh deploy ha
```

Harvester has no cost estimate, so `cluster.sh cost` does not apply.

## Verify

```bash
clusters/ha/kubeconfig.sh --wait -o ~/.kube/aif-ha.yaml
export KUBECONFIG=~/.kube/aif-ha.yaml
kubectl get nodes                              # 9 nodes, Ready
kubectl get pods -n longhorn-system
kubectl describe node | grep nvidia.com/gpu    # untested on Harvester
```

## Destroy

```bash
tools/multicluster/cluster.sh destroy ha
```

After a successful destroy, `deploy.sh` prints a leftovers check for `tools/leftovers/harvester.sh`. It does not run it; run it yourself with your kubeconfig for the Harvester cluster. It deletes nothing.

## Troubleshooting

- Plan fails on `api_vip` or `ingress_vip`: an address is outside `vpc_cidr`, the two are equal, or the address is already in use. The plan does not check DHCP leases; a duplicate address shows up at boot.
- Plan fails on the image, the network or the GPU device: `jumphost_image`, `vpc_id` or the PCI device does not exist or is not enabled for passthrough.
- Nodes stay Pending: Harvester has no free capacity for the plans. The plan does not read host capacity.
- Platform notes and the first-deploy checklist: [docs/providers/harvester.md](../../../docs/providers/harvester.md).
