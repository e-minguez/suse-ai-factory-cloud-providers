# 04: Management and GPU downstream with storage on OCI

Shape overview: [../README.md](../README.md). Status: not run end to end on OCI yet; `make test-catalog` plans every file.
The `gpu` cluster adds three storage nodes (pool `storage`, SUSE Storage on the root disk) and two worker nodes.

## Prerequisites

- The shared prerequisites: [../../README.md#shared-prerequisites](../../README.md#shared-prerequisites).
  This includes `clusters/common-all.tfvars` and `clusters/common-oci.tfvars`
  with the `oci_*` credentials, `oci_compartment_ocid`, the region and `admin_cidrs`.
- Application Collection credentials (`appco_username`, `appco_password`) are required by local-path-provisioner.
- A service limit of at least `gpu-a10-count` = 1 per GPU node in the availability domain (new tenancies start at 0; request it in the console). The plan fails when the shape is not offered or the limit is short. VM GPU shapes only: bare metal GPU shapes cannot boot the imported image.
- Compute limits for the shapes below (`standard-e5-core-count`, `standard-e5-memory-count`) and one network load balancer and one reserved public IP per cluster; the plan checks them.
- Go, for the cost estimate.
- Each cluster has its own VCN with the default `vpc_cidr` `10.20.0.0/20`. The clusters talk to each other through the load balancer addresses and DNS names only. A tenancy limits the VCNs per region; each cluster adds one.

## Steps

Run from the repo root, in order.

1. Create, edit and deploy `mgmt`.

   ```bash
   tools/multicluster/cluster.sh new --empty oci mgmt
   cp catalog/04-mgmt-gpu-storage/oci/mgmt.tfvars.example clusters/mgmt/terraform.tfvars
   $EDITOR clusters/mgmt/terraform.tfvars
   tools/multicluster/cluster.sh cost mgmt
   tools/multicluster/cluster.sh deploy mgmt
   ```

2. Create, edit and deploy `gpu`.

   ```bash
   tools/multicluster/cluster.sh new --empty oci gpu
   cp catalog/04-mgmt-gpu-storage/oci/gpu.tfvars.example clusters/gpu/terraform.tfvars
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

Delete the imported cluster in the Rancher UI and remove `gpu` from `clusters/.register/mgmt/downstream.list`; delete `clusters/.register/mgmt/` before a new `mgmt`. After a successful destroy, `deploy.sh` prints a leftovers check for `tools/leftovers/oci.sh`. It does not run it; run it yourself with your OCI credentials. It deletes nothing.

## Troubleshooting

- Plan fails with "Service limits too low" or "Shapes not offered": request the limit or choose another availability domain (`zones = ["ad-2"]`).
- "Out of host capacity" at apply: capacity cannot be checked at plan; retry later or use another availability domain.
- Platform notes and the first-deploy checklist: [docs/providers/oci.md](../../../docs/providers/oci.md), [examples/oci/README.md](../../../examples/oci/README.md).
