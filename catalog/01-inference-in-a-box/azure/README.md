# 01: Inference in a box on Azure

Shape overview: [../README.md](../README.md). Status: not run end to end on Azure yet; `make test-catalog` plans it.

## Prerequisites

- The shared prerequisites: [../../README.md#shared-prerequisites](../../README.md#shared-prerequisites).
  This includes `clusters/common-all.tfvars` and `clusters/common-azure.tfvars`
  with `azure_subscription_id` (plus the service principal values unless you use `az login`), the region and `admin_cidrs`.
- Application Collection credentials (`appco_username`, `appco_password`) are required by local-path-provisioner.
- vCPU quota for the family of the GPU size in the region: `Standard NCASv3_T4 Family vCPUs`, 16 per `Standard_NC16as_T4_v3` node (new subscriptions start at 0; request it in the portal under Subscriptions, Usage + quotas). The plan fails when a size is not offered in the region or zone, is restricted for the subscription, or the quota is short. Generation 2 VM sizes with Premium SSD only: fractional vGPU sizes and arm64 sizes cannot boot the image.
- Quota for the other sizes (`Standard DSv5 Family vCPUs`, `Total Regional vCPUs`), and per cluster one Standard load balancer and three Standard public IPs (load balancer, NAT gateway, jumphost); the plan checks them. The resource providers `Microsoft.Compute`, `Microsoft.Network` and `Microsoft.Storage` registered, and shared key access allowed on storage accounts ([examples/azure/README.md](../../../examples/azure/README.md#prerequisites)).
- Go, for the cost estimate.
- The example size `Standard_NC16as_T4_v3` has 16 vCPUs, 110 GB RAM and one T4 (16 GB), so it needs 16 vCPUs of `Standard NCASv3_T4 Family vCPUs` plus 4 `Standard DSv5 Family vCPUs` for the jumphost (`Standard_D4s_v5`, which stays as SSH bastion). Check that your region offers it.

## Steps

```bash
tools/multicluster/cluster.sh new --empty azure box
cp catalog/01-inference-in-a-box/azure/box.tfvars.example clusters/box/terraform.tfvars   # cp keeps the 600 mode
$EDITOR clusters/box/terraform.tfvars
tools/multicluster/cluster.sh cost box
tools/multicluster/cluster.sh deploy box
```

One pass: the jumphost builds the image (30 to 60 minutes), Azure imports it, then the node boots.

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

After a successful destroy, `deploy.sh` prints a leftovers check for `tools/leftovers/azure.sh`. It does not run it; run it yourself with your Azure credentials. It deletes nothing.

## Troubleshooting

- Plan fails with "Quota too low" or "VM sizes not usable": request the quota, pick a region or zone that offers the size, or set the pool `zone`.
- `AllocationFailed` or `ZonalAllocationFailed` at apply: capacity cannot be checked at plan; retry later or use another zone or region.
- Prerequisites and the first-deploy checklist: [examples/azure/README.md](../../../examples/azure/README.md).
