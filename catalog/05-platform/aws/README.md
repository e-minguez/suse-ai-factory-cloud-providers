# 05: Platform on AWS

Shape overview: [../README.md](../README.md). Status: not run end to end on AWS yet; `make test-catalog` plans every file.

The order, tokens, the Observability license and the registration steps are the same as in the
[vultr guide](../vultr/README.md); the provider and the DNS records change. Create the four clusters
with `tools/multicluster/cluster.sh new --empty aws <name>` and copy
`catalog/05-platform/aws/<name>.tfvars.example` (`mgmt`, `sec`, `obs`, `gpu`).

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
- `obs` runs on one `c7i.8xlarge` node (32 vCPU, 64 GB) with a 1000 GB root volume (`control_plane_disk_size_gb`). Totals with a jumphost per cluster (`c6i.xlarge`, 4 vCPU): 84 standard vCPU and 8 G and VT vCPU (one `g5.2xlarge`).
- Replace every `example.com` domain and create the DNS records below.
- Each cluster has its own VPC (default `vpc_cidr` `10.20.0.0/20`), NAT gateway with one Elastic IP and two network load balancers. The clusters talk to each other through the public load balancer DNS names only. The default quotas are 5 VPCs and 5 Elastic IPs per region; each cluster adds one of each. With the default VPC of the region, four clusters reach the VPC limit.

## How the DNS records work on AWS

The ingress of each cluster is a network load balancer with a DNS name, not a
fixed IP you choose, so each wildcard record is a CNAME:

| Cluster | Record in the zone `aif.example.com` |
|---|---|
| `obs` | `*.o11y  CNAME  <obs public load balancer DNS name>` |
| `sec` | `*.sec  CNAME  <sec public load balancer DNS name>` |
| `mgmt` | `*.mgmt  CNAME  <mgmt public load balancer DNS name>` |
| `gpu` | `*.gpu  CNAME  <gpu public load balancer DNS name>` |

The load balancer `<cluster_name>-public` exists early in the apply, while the
image builds. Read its name then, or from `ingress_endpoint` after `deploy`:

```bash
aws elbv2 describe-load-balancers --names aif-obs-public --query 'LoadBalancers[0].DNSName' --output text
terraform -chdir=clusters/obs output -raw ingress_endpoint   # https://<DNS name>, after deploy
```

With Route 53, an alias A record to the load balancer works too. DuckDNS accepts
A records only: use one of the addresses of the DNS name (`dig +short <DNS name>`).
The load balancer has one fixed address per zone and balances across zones, so
any of them reaches every node.

## Verify and destroy

Follow the shape README and the vultr guide, with `clusters/<name>/kubeconfig.sh` per cluster. Destroy in reverse order (`gpu`, `mgmt`, `sec`, `obs`). After a successful destroy, `deploy.sh` prints a leftovers check for `tools/leftovers/aws.sh`. It does not run it; run it yourself with your AWS credentials. It deletes nothing.

## Troubleshooting

- Plan fails with "Instance type ... is not offered in ...": the zone does not offer the type. Set `zones` (the first entry hosts single nodes and pools without `zone`) or a pool `zone`.
- `VcpuLimitExceeded` at apply: request the quota increase in Service Quotas, then run `deploy` again.
- `InsufficientInstanceCapacity` at apply: the plan checks the offering, not capacity. `modules/aws/scripts/check-and-reserve.sh --region <region> --max-cost-per-hour <usd> --zones <zones>` finds and reserves an available GPU type ([aws.md](../../../docs/providers/aws.md#gpu-quota-and-drivers)).
- `OptInRequired` at `aws_instance.jumphost`: accept the Marketplace listing.
- Platform notes: [docs/providers/aws.md](../../../docs/providers/aws.md), [examples/aws/README.md](../../../examples/aws/README.md).
