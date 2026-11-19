# 05: Platform on Harvester

Shape overview: [../README.md](../README.md). Status: not run end to end on Harvester yet; the GPU cluster is untested (no GPU passthrough tested yet).

The order, DNS records, tokens, the Observability license and the registration steps are the same as in the
[vultr guide](../vultr/README.md); only the provider changes. Create the four clusters
with `tools/multicluster/cluster.sh new --empty harvester <name>` and copy
`catalog/05-platform/harvester/<name>.tfvars.example` (`mgmt`, `sec`, `obs`, `gpu`).

## Prerequisites

- The shared prerequisites: [../../README.md#shared-prerequisites](../../README.md#shared-prerequisites).
  This includes `clusters/common-all.tfvars`. Harvester values go in `clusters/common-harvester.tfvars`
  (mode 600): optionally `harvester_kubeconfig_path` (else the kubeconfig comes from
  `KUBECONFIG`), `harvester_namespace`, `vpc_id` (`<namespace>/<network>`), `vpc_cidr` (the real subnet
  of that network) and `region` (a label, `"harvester"`). `harvester_kubecontext` is optional. These values
  are not in the cluster files.
- Harvester 1.8 or later with an existing namespace and an existing VM network (`vpc_id`). Creating networks is not part of the module.
- Two free static IPv4 addresses in `vpc_cidr` per cluster, outside the DHCP range, all distinct: `mgmt` `.40` and `.41`, `gpu` `.42` and `.43`, `obs` `.44` and `.45`, `sec` `.46` and `.47`.
- Harvester downloads the openSUSE Leap cloud image from `buildhost_image_url` unless `jumphost_image` names an existing image in the namespace. The cluster needs outbound access for that download.
- Application Collection credentials (`appco_username`, `appco_password`) are required by local-path-provisioner.
- The GPU cluster needs PCI passthrough enabled on Harvester (`pcidevices-controller`) and the GPU bound to passthrough. The GPU path is not tested on Harvester yet, so the `gpu` cluster is untested.
- `obs` runs on one `32x64` node (32 vCPU, 64 GiB) with a 1000 GB root disk (`control_plane_disk_size_gb`). Check that the Harvester hosts and the storage class have room for it.
- Replace every `example.com` domain, and create the DNS records of the shape README: the ingress address of each cluster is the `ingress_vip` you set (also in the `provider_details` output).
- Clusters talk through VIPs and DNS names only; they share the VLAN network.

## Verify and destroy

Follow the shape README and the vultr guide, with `clusters/<name>/kubeconfig.sh` per cluster. Destroy in reverse order (`gpu`, `obs`, `sec`, `mgmt`). After a successful destroy, `deploy.sh` prints a leftovers check for `tools/leftovers/harvester.sh`. It does not run it; run it yourself with your kubeconfig for the Harvester cluster. It deletes nothing.

## Troubleshooting

- Plan fails on `api_vip` or `ingress_vip`: an address is outside `vpc_cidr`, two addresses are equal, or an address is already in use. The plan does not check DHCP leases.
- Plan fails on the image, the network or the GPU device: `jumphost_image`, `vpc_id` or the PCI device does not exist or is not enabled for passthrough.
- Nodes stay Pending: Harvester has no free capacity for the plans. The plan does not read host capacity.
- Platform notes and the first-deploy checklist: [docs/providers/harvester.md](../../../docs/providers/harvester.md).
