# 05: Platform on OCI

Shape overview: [../README.md](../README.md). Status: not run end to end on OCI yet; `make test-catalog` plans every file.

The order, DNS records, tokens, the Observability license and the registration steps are the same as in the
[vultr guide](../vultr/README.md); only the provider changes. Create the four clusters
with `tools/multicluster/cluster.sh new --empty oci <name>` and copy
`catalog/05-platform/oci/<name>.tfvars.example` (`mgmt`, `sec`, `obs`, `gpu`).

## Prerequisites

- The shared prerequisites: [../../README.md#shared-prerequisites](../../README.md#shared-prerequisites).
  This includes `clusters/common-all.tfvars` and `clusters/common-oci.tfvars`
  with the `oci_*` credentials, `oci_compartment_ocid`, the region and `admin_cidrs`.
- Application Collection credentials (`appco_username`, `appco_password`) are required by local-path-provisioner.
- A service limit of at least `gpu-a10-count` = 1 per GPU node in the availability domain (new tenancies start at 0; request it in the console). The plan fails when the shape is not offered or the limit is short. VM GPU shapes only: bare metal GPU shapes cannot boot the imported image.
- Compute limits for the shapes below (`standard-e5-core-count`, `standard-e5-memory-count`) and one network load balancer and one reserved public IP per cluster; the plan checks them.
- Go, for the cost estimate.
- `obs` runs on one `VM.Standard.E5.Flex:16x64` node with a 1000 GB boot volume (`control_plane_disk_size_gb`). Check `standard-e5-core-count` (at least 16 for it) and the boot volume capacity of your tenancy.
- Replace every `example.com` domain, and create the DNS records of the shape README: the load balancer address of each cluster is `terraform output api_vip`.
- Each cluster has its own VCN with the default `vpc_cidr`; clusters talk through load balancer addresses and DNS names only.

## Verify and destroy

Follow the shape README and the vultr guide, with `clusters/<name>/kubeconfig.sh` per cluster. Destroy in reverse order (`gpu`, `obs`, `sec`, `mgmt`). After a successful destroy, `deploy.sh` prints a leftovers check for `tools/leftovers/oci.sh`. It does not run it; run it yourself with your OCI credentials. It deletes nothing.

## Troubleshooting

- Plan fails with "Service limits too low" or "Shapes not offered": request the limit or choose another availability domain (`zones = ["ad-2"]`).
- "Out of host capacity" at apply: capacity cannot be checked at plan; retry later or use another availability domain.
- Platform notes and the first-deploy checklist: [docs/providers/oci.md](../../../docs/providers/oci.md), [examples/oci/README.md](../../../examples/oci/README.md).
