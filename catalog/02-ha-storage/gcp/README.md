# 02: HA cluster with storage on GCP

Shape overview: [../README.md](../README.md). Status: not run end to end on GCP yet; `make test-catalog` plans it.

## Prerequisites

- The shared prerequisites: [../../README.md#shared-prerequisites](../../README.md#shared-prerequisites).
  This includes `clusters/common-all.tfvars` and `clusters/common-gcp.tfvars`
  with `gcp_project`, the region and `admin_cidrs`. Credentials are Application Default Credentials (`gcloud auth application-default login`).
- Application Collection credentials (`appco_username`, `appco_password`) are required by local-path-provisioner.
- A regional quota of at least `NVIDIA_L4_GPUS` = 1 per GPU node, and `GPUS_ALL_REGIONS` (new projects can start at 0; request both in the console, IAM and admin, Quotas). The plan fails when the machine type is not offered in the zone or the quota is short.
- Compute quotas for the machine types below (`CPUS` or `N2_CPUS`, `SSD_TOTAL_GB`) and the reserved addresses of each cluster (`STATIC_ADDRESSES`, `IN_USE_ADDRESSES`); the plan checks them. The Compute Engine API must be enabled.
- Go, for the cost estimate.
- Totals: 3 control planes (`n2-standard-8`: 8 vCPU, 32 GB), 2 general and 3 storage nodes (`n2-standard-4`: 4 vCPU, 16 GB), one GPU node (`g2-standard-8`: 8 vCPU, 32 GB, one L4): 52 vCPUs, 200 GB.

## Steps

```bash
tools/multicluster/cluster.sh new --empty gcp ha
cp catalog/02-ha-storage/gcp/ha.tfvars.example clusters/ha/terraform.tfvars
$EDITOR clusters/ha/terraform.tfvars
tools/multicluster/cluster.sh cost ha
tools/multicluster/cluster.sh deploy ha
```

Control planes run in the first zone of the region; add `zones = ["europe-west4-a", "europe-west4-b", "europe-west4-c"]` to spread them over several.

## Verify

```bash
clusters/ha/kubeconfig.sh --wait -o ~/.kube/aif-ha.yaml
export KUBECONFIG=~/.kube/aif-ha.yaml
kubectl get nodes                              # 9 nodes, Ready
kubectl get pods -n longhorn-system
kubectl describe node | grep nvidia.com/gpu
```

## Destroy

```bash
tools/multicluster/cluster.sh destroy ha
```

After a successful destroy, `deploy.sh` prints a leftovers check for `tools/leftovers/gcp.sh`. It does not run it; run it yourself with your gcloud credentials. It deletes nothing.

## Troubleshooting

- Plan fails with a quota or "not offered in <zone>" message: request the named quota or choose another zone (`zones = ["europe-west4-b"]`).
- `ZONE_RESOURCE_POOL_EXHAUSTED` at apply: capacity cannot be checked at plan; retry later or use another zone.
- Platform notes and the first-deploy checklist: [docs/providers/gcp.md](../../../docs/providers/gcp.md), [examples/gcp/README.md](../../../examples/gcp/README.md).
