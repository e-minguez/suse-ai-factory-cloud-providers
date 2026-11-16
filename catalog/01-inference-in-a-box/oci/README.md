# 01: Inference in a box on OCI

Shape overview: [../README.md](../README.md). Status: not run end to end on OCI yet; `make test-catalog` plans it.

## Prerequisites

- The shared prerequisites: [../../README.md#shared-prerequisites](../../README.md#shared-prerequisites).
  This includes `clusters/common-all.tfvars` and `clusters/common-oci.tfvars`
  with the `oci_*` credentials, `oci_compartment_ocid`, the region and `admin_cidrs`.
- Application Collection credentials (`appco_username`, `appco_password`) are required by local-path-provisioner.
- A service limit of at least `gpu-a10-count` = 1 per GPU node in the availability domain (new tenancies start at 0; request it in the console). The plan fails when the shape is not offered or the limit is short. VM GPU shapes only: bare metal GPU shapes cannot boot the imported image.
- Compute limits for the shapes below (`standard-e5-core-count`, `standard-e5-memory-count`) and one network load balancer and one reserved public IP per cluster; the plan checks them.
- Go, for the cost estimate.
- The example shape `VM.GPU.A10.1` has 15 OCPUs, 240 GB RAM and one A10 (24 GB). `eu-frankfurt-1` offers it.

## Steps

```bash
tools/multicluster/cluster.sh new --empty oci box
cp catalog/01-inference-in-a-box/oci/box.tfvars.example clusters/box/terraform.tfvars   # cp keeps the 600 mode
$EDITOR clusters/box/terraform.tfvars
tools/multicluster/cluster.sh cost box
tools/multicluster/cluster.sh deploy box
```

One pass: the jumphost builds the image (30 to 60 minutes), OCI imports it, then the node boots.

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

After a successful destroy, `deploy.sh` prints a leftovers check for `tools/leftovers/oci.sh`. It does not run it; run it yourself with your OCI credentials. It deletes nothing.

## Troubleshooting

- Plan fails with "Service limits too low" or "Shapes not offered": request the limit or choose another availability domain (`zones = ["ad-2"]`).
- "Out of host capacity" at apply: capacity cannot be checked at plan; retry later or use another availability domain.
- Platform notes and the first-deploy checklist: [docs/providers/oci.md](../../../docs/providers/oci.md), [examples/oci/README.md](../../../examples/oci/README.md).
