# 02: HA cluster with storage on OCI

Shape overview: [../README.md](../README.md). Status: not run end to end on OCI yet; `make test-catalog` plans it.

## Prerequisites

- The shared prerequisites: [../../README.md#shared-prerequisites](../../README.md#shared-prerequisites).
  This includes `clusters/common-all.tfvars` and `clusters/common-oci.tfvars`
  with the `oci_*` credentials, `oci_compartment_ocid`, the region and `admin_cidrs`.
- Application Collection credentials (`appco_username`, `appco_password`) are required by local-path-provisioner.
- A service limit of at least `gpu-a10-count` = 1 per GPU node in the availability domain (new tenancies start at 0; request it in the console). The plan fails when the shape is not offered or the limit is short. VM GPU shapes only: bare metal GPU shapes cannot boot the imported image.
- Compute limits for the shapes below (`standard-e5-core-count`, `standard-e5-memory-count`) and one network load balancer and one reserved public IP per cluster; the plan checks them.
- Go, for the cost estimate.
- Totals: 3 control planes (4 OCPU, 32 GB), 2 general and 3 storage nodes (4 OCPU, 16 GB), one GPU node: 36 OCPUs, 152 GB plus one `VM.GPU.A10.1`.

## Steps

```bash
tools/multicluster/cluster.sh new --empty oci ha
cp catalog/02-ha-storage/oci/ha.tfvars.example clusters/ha/terraform.tfvars
$EDITOR clusters/ha/terraform.tfvars
tools/multicluster/cluster.sh cost ha
tools/multicluster/cluster.sh deploy ha
```

Control planes spread over fault domains of the first availability domain; add `zones = ["ad-1", "ad-2"]` to spread over several.

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

After a successful destroy, `deploy.sh` prints a leftovers check for `tools/leftovers/oci.sh`. It does not run it; run it yourself with your OCI credentials. It deletes nothing.

## Troubleshooting

- Plan fails with "Service limits too low" or "Shapes not offered": request the limit or choose another availability domain (`zones = ["ad-2"]`).
- "Out of host capacity" at apply: capacity cannot be checked at plan; retry later or use another availability domain.
- Platform notes and the first-deploy checklist: [docs/providers/oci.md](../../../docs/providers/oci.md), [examples/oci/README.md](../../../examples/oci/README.md).
