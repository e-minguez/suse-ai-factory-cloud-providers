# 01: Inference in a box on AWS

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
- The example type `g5.4xlarge` has 16 vCPU, 64 GB RAM and one A10G (24 GB): a G and VT quota of at least 16 vCPU, plus 4 standard vCPU for the jumphost (`c6i.xlarge`), which stays as SSH bastion.
- The node runs in the first zone of `zones` (default: the first three zones of the region). Check that it offers the type:
  `aws ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values=g5.4xlarge --region <region>`.

## Steps

```bash
tools/multicluster/cluster.sh new --empty aws box
cp catalog/01-inference-in-a-box/aws/box.tfvars.example clusters/box/terraform.tfvars   # cp keeps the 600 mode
$EDITOR clusters/box/terraform.tfvars
tools/multicluster/cluster.sh cost box
tools/multicluster/cluster.sh deploy box
```

One pass: the jumphost builds the image and uploads it to S3, AWS imports it as an AMI, then the node boots.
Rancher and the RKE2 API use the DNS names of the load balancers; set `ingress_domain` for your own names.

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

After a successful destroy, `deploy.sh` prints a leftovers check for `tools/leftovers/aws.sh`. It does not run it; run it yourself with your AWS credentials. It deletes nothing.

## Troubleshooting

- Plan fails with "Instance type ... is not offered in ...": the zone does not offer the type. Set `zones` (the first entry hosts single nodes and pools without `zone`) or a pool `zone`.
- `VcpuLimitExceeded` at apply: request the quota increase in Service Quotas, then run `deploy` again.
- `InsufficientInstanceCapacity` at apply: the plan checks the offering, not capacity. `modules/aws/scripts/check-and-reserve.sh --region <region> --max-cost-per-hour <usd> --zones <zones>` finds and reserves an available GPU type ([aws.md](../../../docs/providers/aws.md#gpu-quota-and-drivers)).
- `OptInRequired` at `aws_instance.jumphost`: accept the Marketplace listing.
- Platform notes: [docs/providers/aws.md](../../../docs/providers/aws.md), [examples/aws/README.md](../../../examples/aws/README.md).
