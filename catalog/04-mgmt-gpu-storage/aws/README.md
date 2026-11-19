# 04: Management and GPU downstream with storage on AWS

Shape overview: [../README.md](../README.md). Status: not run end to end on AWS yet; `make test-catalog` plans every file.
The `gpu` cluster adds three storage nodes (pool `storage`, SUSE Storage on the root disk) and two worker nodes.

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
- Totals: `mgmt` has 3 control planes (default `m7i.xlarge`, 4 vCPU, 16 GB); `gpu` has 3 control planes, 5 `m7i.xlarge` workers and one `g5.2xlarge` (8 vCPU, one A10G). With a jumphost per cluster (`c6i.xlarge`, 4 vCPU): 52 standard vCPU and 8 G and VT vCPU.
- Each cluster has its own VPC (default `vpc_cidr` `10.20.0.0/20`), NAT gateway with one Elastic IP and two network load balancers. The clusters talk to each other through the public load balancer DNS names only. The default quotas are 5 VPCs and 5 Elastic IPs per region; each cluster adds one of each.

## Steps

Run from the repo root, in order.

1. Create, edit and deploy `mgmt`.

   ```bash
   tools/multicluster/cluster.sh new --empty aws mgmt
   cp catalog/04-mgmt-gpu-storage/aws/mgmt.tfvars.example clusters/mgmt/terraform.tfvars
   $EDITOR clusters/mgmt/terraform.tfvars
   tools/multicluster/cluster.sh cost mgmt
   tools/multicluster/cluster.sh deploy mgmt
   ```

2. Create, edit and deploy `gpu`.

   ```bash
   tools/multicluster/cluster.sh new --empty aws gpu
   cp catalog/04-mgmt-gpu-storage/aws/gpu.tfvars.example clusters/gpu/terraform.tfvars
   $EDITOR clusters/gpu/terraform.tfvars
   tools/multicluster/cluster.sh cost gpu
   tools/multicluster/cluster.sh deploy gpu
   ```

Import `gpu` into the management Rancher (`--bootstrap` once; see [tools/multicluster/README.md](../../../tools/multicluster/README.md)):

```bash
tools/multicluster/cluster.sh register --bootstrap mgmt gpu
```

`register` checks that the `mgmt` `ingress_cidrs` include the `gpu` egress address (the NAT gateway Elastic IP, `terraform output egress_ips`). The default `0.0.0.0/0` passes.

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

Delete the imported cluster in the Rancher UI and remove `gpu` from `clusters/.register/mgmt/downstream.list`; delete `clusters/.register/mgmt/` before a new `mgmt`. After a successful destroy, `deploy.sh` prints a leftovers check for `tools/leftovers/aws.sh`. It does not run it; run it yourself with your AWS credentials. It deletes nothing.

## Troubleshooting

- Plan fails with "Instance type ... is not offered in ...": the zone does not offer the type. Set `zones` (the first entry hosts single nodes and pools without `zone`) or a pool `zone`.
- `VcpuLimitExceeded` at apply: request the quota increase in Service Quotas, then run `deploy` again.
- `InsufficientInstanceCapacity` at apply: the plan checks the offering, not capacity. `modules/aws/scripts/check-and-reserve.sh --region <region> --max-cost-per-hour <usd> --zones <zones>` finds and reserves an available GPU type ([aws.md](../../../docs/providers/aws.md#gpu-quota-and-drivers)).
- `OptInRequired` at `aws_instance.jumphost`: accept the Marketplace listing.
- Platform notes: [docs/providers/aws.md](../../../docs/providers/aws.md), [examples/aws/README.md](../../../examples/aws/README.md).
