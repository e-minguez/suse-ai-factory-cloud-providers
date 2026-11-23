# 05: Platform on Azure

Shape overview: [../README.md](../README.md). Status: not run end to end on Azure yet; `make test-catalog` plans every file.

The order, DNS records, tokens, the Observability license and the registration steps are the same as in the
[vultr guide](../vultr/README.md); only the provider changes. Create the four clusters
with `tools/multicluster/cluster.sh new --empty azure <name>` and copy
`catalog/05-platform/azure/<name>.tfvars.example` (`mgmt`, `sec`, `obs`, `gpu`).

## Prerequisites

- The shared prerequisites: [../../README.md#shared-prerequisites](../../README.md#shared-prerequisites).
  This includes `clusters/common-all.tfvars` and `clusters/common-azure.tfvars`
  with `azure_subscription_id` (plus the service principal values unless you use `az login`), the region and `admin_cidrs`.
- Application Collection credentials (`appco_username`, `appco_password`) are required by local-path-provisioner.
- vCPU quota for the family of the GPU size in the region: `Standard NCASv3_T4 Family vCPUs`, 4 per `Standard_NC4as_T4_v3` node (new subscriptions start at 0; request it in the portal under Subscriptions, Usage + quotas). The plan fails when a size is not offered in the region or zone, is restricted for the subscription, or the quota is short. Generation 2 VM sizes with Premium SSD only: fractional vGPU sizes and arm64 sizes cannot boot the image.
- Quota for the other sizes (`Standard DSv5 Family vCPUs`, `Total Regional vCPUs`), and per cluster one Standard load balancer and three Standard public IPs (load balancer, NAT gateway, jumphost); the plan checks them. The resource providers `Microsoft.Compute`, `Microsoft.Network` and `Microsoft.Storage` registered, and shared key access allowed on storage accounts ([examples/azure/README.md](../../../examples/azure/README.md#prerequisites)).
- Go, for the cost estimate.
- `obs` runs on one `Standard_D32s_v5` node (32 vCPUs, 128 GB) with a 1000 GB OS disk (`control_plane_disk_size_gb`). Check `Standard DSv5 Family vCPUs` (at least 36 with the jumphost) and the managed disk quota of your subscription.
- Replace every `example.com` domain, and create the DNS records of the shape README: the load balancer address of each cluster is `terraform output api_vip`.
- Each cluster has its own resource group and virtual network with the default `vpc_cidr`; clusters talk through load balancer addresses and DNS names only.

## Verify and destroy

Follow the shape README and the vultr guide, with `clusters/<name>/kubeconfig.sh` per cluster. Destroy in reverse order (`gpu`, `obs`, `sec`, `mgmt`). After a successful destroy, `deploy.sh` prints a leftovers check for `tools/leftovers/azure.sh`. It does not run it; run it yourself with your Azure credentials. It deletes nothing.

## Troubleshooting

- Plan fails with "Quota too low" or "VM sizes not usable": request the quota, pick a region or zone that offers the size, or set the pool `zone`.
- `AllocationFailed` or `ZonalAllocationFailed` at apply: capacity cannot be checked at plan; retry later or use another zone or region.
- Prerequisites and the first-deploy checklist: [examples/azure/README.md](../../../examples/azure/README.md).
