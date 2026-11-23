# 04: Management and GPU downstream with storage on GCP

Shape overview: [../README.md](../README.md). Status: not run end to end on GCP yet; `make test-catalog` plans every file.
The `gpu` cluster adds three storage nodes (pool `storage`, SUSE Storage on the root disk) and two worker nodes.

## Prerequisites

- The shared prerequisites: [../../README.md#shared-prerequisites](../../README.md#shared-prerequisites).
  This includes `clusters/common-all.tfvars` and `clusters/common-gcp.tfvars`
  with `gcp_project`, the region and `admin_cidrs`. Credentials are Application Default Credentials (`gcloud auth application-default login`).
- Application Collection credentials (`appco_username`, `appco_password`) are required by local-path-provisioner.
- A regional quota of at least `NVIDIA_L4_GPUS` = 1 per GPU node, and `GPUS_ALL_REGIONS` (new projects can start at 0; request both in the console, IAM and admin, Quotas). The plan fails when the machine type is not offered in the zone or the quota is short.
- Compute quotas for the machine types below (`CPUS` or `N2_CPUS`, `SSD_TOTAL_GB`) and the reserved addresses of each cluster (`STATIC_ADDRESSES`, `IN_USE_ADDRESSES`); the plan checks them. The Compute Engine API must be enabled.
- Go, for the cost estimate.
- Each cluster has its own VPC with the default `vpc_cidr` `10.20.0.0/20`. The clusters talk to each other through the load balancer addresses and DNS names only. The project quota `NETWORKS` limits the VPCs; each cluster adds one.

## Steps

Run from the repo root, in order.

1. Create, edit and deploy `mgmt`.

   ```bash
   tools/multicluster/cluster.sh new --empty gcp mgmt
   cp catalog/04-mgmt-gpu-storage/gcp/mgmt.tfvars.example clusters/mgmt/terraform.tfvars
   $EDITOR clusters/mgmt/terraform.tfvars
   tools/multicluster/cluster.sh cost mgmt
   tools/multicluster/cluster.sh deploy mgmt
   ```

2. Create, edit and deploy `gpu`.

   ```bash
   tools/multicluster/cluster.sh new --empty gcp gpu
   cp catalog/04-mgmt-gpu-storage/gcp/gpu.tfvars.example clusters/gpu/terraform.tfvars
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

Delete the imported cluster in the Rancher UI and remove `gpu` from `clusters/.register/mgmt/downstream.list`; delete `clusters/.register/mgmt/` before a new `mgmt`. After a successful destroy, `deploy.sh` prints a leftovers check for `tools/leftovers/gcp.sh`. It does not run it; run it yourself with your gcloud credentials. It deletes nothing.

## Troubleshooting

- Plan fails with a quota or "not offered in <zone>" message: request the named quota or choose another zone (`zones = ["europe-west4-b"]`).
- `ZONE_RESOURCE_POOL_EXHAUSTED` at apply: capacity cannot be checked at plan; retry later or use another zone.
- Platform notes and the first-deploy checklist: [docs/providers/gcp.md](../../../docs/providers/gcp.md), [examples/gcp/README.md](../../../examples/gcp/README.md).
