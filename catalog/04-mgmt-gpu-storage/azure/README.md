# 04: Management and GPU downstream with storage on Azure

Shape overview: [../README.md](../README.md). Status: not run end to end on Azure yet; `make test-catalog` plans every file.
The `gpu` cluster adds three storage nodes (pool `storage`, SUSE Storage on the root disk) and two worker nodes.

## Prerequisites

- The shared prerequisites: [../../README.md#shared-prerequisites](../../README.md#shared-prerequisites).
  This includes `clusters/common-all.tfvars` and `clusters/common-azure.tfvars`
  with `azure_subscription_id` (plus the service principal values unless you use `az login`), the region and `admin_cidrs`.
- Application Collection credentials (`appco_username`, `appco_password`) are required by local-path-provisioner.
- vCPU quota for the family of the GPU size in the region: `Standard NCASv3_T4 Family vCPUs`, 4 per `Standard_NC4as_T4_v3` node (new subscriptions start at 0; request it in the portal under Subscriptions, Usage + quotas). The plan fails when a size is not offered in the region or zone, is restricted for the subscription, or the quota is short. Generation 2 VM sizes with Premium SSD only: fractional vGPU sizes and arm64 sizes cannot boot the image.
- Quota for the other sizes (`Standard DSv5 Family vCPUs`, `Total Regional vCPUs`), and per cluster one Standard load balancer and three Standard public IPs (load balancer, NAT gateway, jumphost); the plan checks them. The resource providers `Microsoft.Compute`, `Microsoft.Network` and `Microsoft.Storage` registered, and shared key access allowed on storage accounts ([examples/azure/README.md](../../../examples/azure/README.md#prerequisites)).
- Go, for the cost estimate.
- Each cluster has its own resource group and virtual network with the default `vpc_cidr` `10.20.0.0/20`. The clusters talk to each other through the load balancer addresses and DNS names only.

## Steps

Run from the repo root, in order.

1. Create, edit and deploy `mgmt`.

   ```bash
   tools/multicluster/cluster.sh new --empty azure mgmt
   cp catalog/04-mgmt-gpu-storage/azure/mgmt.tfvars.example clusters/mgmt/terraform.tfvars
   $EDITOR clusters/mgmt/terraform.tfvars
   tools/multicluster/cluster.sh cost mgmt
   tools/multicluster/cluster.sh deploy mgmt
   ```

2. Create, edit and deploy `gpu`.

   ```bash
   tools/multicluster/cluster.sh new --empty azure gpu
   cp catalog/04-mgmt-gpu-storage/azure/gpu.tfvars.example clusters/gpu/terraform.tfvars
   $EDITOR clusters/gpu/terraform.tfvars
   tools/multicluster/cluster.sh cost gpu
   tools/multicluster/cluster.sh deploy gpu
   ```


Import `gpu` into the management Rancher (`--bootstrap` once; see [tools/multicluster/README.md](../../../tools/multicluster/README.md)):

```bash
tools/multicluster/cluster.sh register --bootstrap mgmt gpu
```

`register` checks that the `mgmt` `ingress_cidrs` include the `gpu` egress address (the NAT gateway address, `terraform output egress_ips`). The default `0.0.0.0/0` passes.

## Verify

```bash
tools/multicluster/cluster.sh list
terraform -chdir=clusters/mgmt output -raw rancher_url
clusters/gpu/kubeconfig.sh --wait -o ~/.kube/aif-gpu.yaml
KUBECONFIG=~/.kube/aif-gpu.yaml kubectl get nodes
KUBECONFIG=~/.kube/aif-gpu.yaml kubectl get pods -n gpu-operator
```

The cluster `aif-gpu` is listed and `Active` in Rancher; the GPU node reports `nvidia.com/gpu`.

## Destroy

Destroy the downstream cluster first.

```bash
tools/multicluster/cluster.sh destroy gpu
tools/multicluster/cluster.sh destroy mgmt
```

Delete the imported cluster in the Rancher UI and remove `gpu` from `clusters/.register/mgmt/downstream.list`; delete `clusters/.register/mgmt/` before a new `mgmt`. After a successful destroy, `deploy.sh` prints a leftovers check for `tools/leftovers/azure.sh`. It does not run it; run it yourself with your Azure credentials. It deletes nothing.

## Troubleshooting

- Plan fails with "Quota too low" or "VM sizes not usable": request the quota, pick a region or zone that offers the size, or set the pool `zone`.
- `AllocationFailed` or `ZonalAllocationFailed` at apply: capacity cannot be checked at plan; retry later or use another zone or region.
- Prerequisites and the first-deploy checklist: [examples/azure/README.md](../../../examples/azure/README.md).
