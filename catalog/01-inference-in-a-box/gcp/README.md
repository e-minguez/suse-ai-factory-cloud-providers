# 01: Inference in a box on GCP

Shape overview: [../README.md](../README.md). Status: not run end to end on GCP yet; `make test-catalog` plans it.

## Prerequisites

- The shared prerequisites: [../../README.md#shared-prerequisites](../../README.md#shared-prerequisites).
  This includes `clusters/common-all.tfvars` and `clusters/common-gcp.tfvars`
  with `gcp_project`, the region and `admin_cidrs`. Credentials are Application Default Credentials (`gcloud auth application-default login`).
- Application Collection credentials (`appco_username`, `appco_password`) are required by local-path-provisioner.
- A regional quota of at least `NVIDIA_L4_GPUS` = 1 per GPU node, and `GPUS_ALL_REGIONS` (new projects can start at 0; request both in the console, IAM and admin, Quotas). The plan fails when the machine type is not offered in the zone or the quota is short.
- Compute quotas for the machine types below (`CPUS` or `N2_CPUS`, `SSD_TOTAL_GB`) and the reserved addresses of each cluster (`STATIC_ADDRESSES`, `IN_USE_ADDRESSES`); the plan checks them. The Compute Engine API must be enabled.
- Go, for the cost estimate.
- The example machine type `g2-standard-16` has 16 vCPUs, 64 GB RAM and one L4 (24 GB). `europe-west4` offers it in zones a, b and c.

## Steps

```bash
tools/multicluster/cluster.sh new --empty gcp box
cp catalog/01-inference-in-a-box/gcp/box.tfvars.example clusters/box/terraform.tfvars   # cp keeps the 600 mode
$EDITOR clusters/box/terraform.tfvars
tools/multicluster/cluster.sh cost box
tools/multicluster/cluster.sh deploy box
```

One pass: the jumphost builds the image (about 20 to 40 minutes), a snapshot of its build disk becomes the image, then the nodes boot.

## Verify

```bash
mkdir -p ~/.kube
clusters/box/kubeconfig.sh --wait -o ~/.kube/aif-box.yaml
export KUBECONFIG=~/.kube/aif-box.yaml
kubectl get nodes                              # one node, Ready
kubectl get pods -A
kubectl describe node | grep nvidia.com/gpu    # GPU capacity 1
terraform -chdir=clusters/box output -raw next_steps
```

## Destroy

```bash
tools/multicluster/cluster.sh destroy box
```

After a successful destroy, `deploy.sh` prints a leftovers check for `tools/leftovers/gcp.sh`. It does not run it; run it yourself with your gcloud credentials. It deletes nothing.

## Troubleshooting

- Plan fails with a quota or "not offered in <zone>" message: request the named quota or choose another zone (`zones = ["europe-west4-b"]`).
- `ZONE_RESOURCE_POOL_EXHAUSTED` at apply: capacity cannot be checked at plan; retry later or use another zone.
- Platform notes and the first-deploy checklist: [docs/providers/gcp.md](../../../docs/providers/gcp.md), [examples/gcp/README.md](../../../examples/gcp/README.md).
