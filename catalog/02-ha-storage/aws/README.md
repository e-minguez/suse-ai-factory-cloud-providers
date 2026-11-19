# 02: HA cluster with storage on AWS

Shape overview: [../README.md](../README.md). Status: not run end to end on AWS yet; `make test-catalog` plans it.

## Prerequisites

- The shared prerequisites: [../../README.md#shared-prerequisites](../../README.md#shared-prerequisites).
  This includes `clusters/common-all.tfvars` and `clusters/common-aws.tfvars`
  with the region and `admin_cidrs`. AWS credentials come from the AWS SDK chain
  (`AWS_PROFILE`, environment, SSO), not from a variable file: export them in the
  shell that runs `cluster.sh` ([AWS credentials](../../../examples/aws/README.md#aws-credentials)).
- The AWS CLI on the workstation: the apply polls S3 with it while the image builds.
- IAM permissions to create roles and an instance profile named `<cluster_name>-*`
  (or pre-created ones, see [aws.md](../../../docs/providers/aws.md#pre-created-iam)).
  IAM names are account-wide: every `cluster_name` must be unique in the account.
- The openSUSE Leap 16 Marketplace listing accepted once per account (the jumphost image;
  [aws.md](../../../docs/providers/aws.md#jumphost-ami-marketplace-listing)).
- Application Collection credentials (`appco_username`, `appco_password`) are required by local-path-provisioner and suse-storage.
- vCPU service quotas in the region: "Running On-Demand G and VT instances" for
  the GPU nodes (a new account usually has 0) and "Running On-Demand Standard
  (A, C, D, H, I, M, R, T, Z) instances" for the others. The plan does not check
  quota: a short quota fails the apply with `VcpuLimitExceeded`. Request the
  increase in Service Quotas first.
- Go, for the cost estimate.
- Totals: 3 control planes (`m7i.2xlarge`, 8 vCPU, 32 GB), 2 general and 3 storage nodes (`m7i.xlarge`, 4 vCPU, 16 GB) and the jumphost (`c6i.xlarge`, 4 vCPU): 48 standard vCPU; one GPU node (`g5.2xlarge`, one A10G): 8 G and VT vCPU.

## Steps

```bash
tools/multicluster/cluster.sh new --empty aws ha
cp catalog/02-ha-storage/aws/ha.tfvars.example clusters/ha/terraform.tfvars
$EDITOR clusters/ha/terraform.tfvars
tools/multicluster/cluster.sh cost ha
tools/multicluster/cluster.sh deploy ha
```

Control planes spread over the first three zones of the region (`zones`). Pools without `zone` use the first one; the plan fails when it does not offer the type.

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

After a successful destroy, `deploy.sh` prints a leftovers check for `tools/leftovers/aws.sh`. It does not run it; run it yourself with your AWS credentials. It deletes nothing.

## Troubleshooting

- Plan fails with "Instance type ... is not offered in ...": the zone does not offer the type. Set `zones` (the first entry hosts single nodes and pools without `zone`) or a pool `zone`.
- `VcpuLimitExceeded` at apply: request the quota increase in Service Quotas, then run `deploy` again.
- `InsufficientInstanceCapacity` at apply: the plan checks the offering, not capacity. `modules/aws/scripts/check-and-reserve.sh --region <region> --max-cost-per-hour <usd> --zones <zones>` finds and reserves an available GPU type ([aws.md](../../../docs/providers/aws.md#gpu-quota-and-drivers)).
- `OptInRequired` at `aws_instance.jumphost`: accept the Marketplace listing.
- Platform notes: [docs/providers/aws.md](../../../docs/providers/aws.md), [examples/aws/README.md](../../../examples/aws/README.md).
