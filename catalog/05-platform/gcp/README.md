# 05: Platform on GCP

Shape overview: [../README.md](../README.md). Status: not run end to end on GCP yet; `make test-catalog` plans every file.

The order, DNS records, tokens, the Observability license and the registration steps are the same as in the
[vultr guide](../vultr/README.md); only the provider changes. Create the four clusters
with `tools/multicluster/cluster.sh new --empty gcp <name>` and copy
`catalog/05-platform/gcp/<name>.tfvars.example` (`mgmt`, `sec`, `obs`, `gpu`).

## Prerequisites

- The shared prerequisites: [../../README.md#shared-prerequisites](../../README.md#shared-prerequisites).
  This includes `clusters/common-all.tfvars` and `clusters/common-gcp.tfvars`
  with `gcp_project`, the region and `admin_cidrs`. Credentials are Application Default Credentials (`gcloud auth application-default login`).
- Application Collection credentials (`appco_username`, `appco_password`) are required by local-path-provisioner.
- A regional quota of at least `NVIDIA_L4_GPUS` = 1 per GPU node, and `GPUS_ALL_REGIONS` (new projects can start at 0; request both in the console, IAM and admin, Quotas). The plan fails when the machine type is not offered in the zone or the quota is short.
- Compute quotas for the machine types below (`CPUS` or `N2_CPUS`, `SSD_TOTAL_GB`) and the reserved addresses of each cluster (`STATIC_ADDRESSES`, `IN_USE_ADDRESSES`); the plan checks them. The Compute Engine API must be enabled.
- Go, for the cost estimate.
- `obs` runs on one `n2-custom-32-65536` node (32 vCPU, 64 GB) with a 1000 GB boot disk (`control_plane_disk_size_gb`). Check the `N2_CPUS` (at least 32 for it) and `SSD_TOTAL_GB` (at least 1000 for it) quotas of the region.
- Replace every `example.com` domain, and create the DNS records of the shape README: the external load balancer address of each cluster is in `terraform output ingress_endpoint`.
- Each cluster has its own VPC with the default `vpc_cidr`; clusters talk through load balancer addresses and DNS names only.

## Verify and destroy

Follow the shape README and the vultr guide, with `clusters/<name>/kubeconfig.sh` per cluster. Destroy in reverse order (`gpu`, `obs`, `sec`, `mgmt`). After a successful destroy, `deploy.sh` prints a leftovers check for `tools/leftovers/gcp.sh`. It does not run it; run it yourself with your gcloud credentials. It deletes nothing.

## Troubleshooting

- Plan fails with a quota or "not offered in <zone>" message: request the named quota or choose another zone (`zones = ["europe-west4-b"]`).
- `ZONE_RESOURCE_POOL_EXHAUSTED` at apply: capacity cannot be checked at plan; retry later or use another zone.
- Platform notes and the first-deploy checklist: [docs/providers/gcp.md](../../../docs/providers/gcp.md), [examples/gcp/README.md](../../../examples/gcp/README.md).
