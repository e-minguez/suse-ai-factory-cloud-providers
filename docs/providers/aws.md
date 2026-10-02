# AWS platform notes

AWS behaviour that shapes the `modules/aws` design. The architecture is in
[modules/aws](../../modules/aws/README.md); how to run it is in
[examples/aws/README.md](../../examples/aws/README.md).

The Elemental image is EFI-only and immutable: no writable root and no
post-boot compilation. Changing what a node runs means building a new image
and replacing the node.

## Passes: one

Diagrams: [architecture](../architecture.md#aws-one-pass).

`deploy.sh` runs a single `terraform apply`. The RKE2 API address
(`network.apiVIP`) is baked into the image, so it must be known before any
resource exists. The internal NLB gets a static private address chosen at plan
time (host 10 of the first private subnet, `local.api_vip`), and target group
attachments are separate resources. The load balancers therefore never
reference `aws_instance`, and there is no cycle between image, load balancer
and nodes.

## Worker pools

- `worker_pools` and `gpu_pools` share one security group (`<cluster_name>-agent`)
  and one `aws_instance.agent` resource, keyed by hostname.
- Control-plane nodes get fixed private IPs (load balancer targets). Worker and
  GPU nodes take a DHCP address, so adding pools or control planes does not
  replace them.

## Boot mode, IMDS and ENA

- Boot mode is a property of the AMI. `aws_ami.ai_factory` sets
  `boot_mode = "uefi"`, so every instance launched from it boots UEFI.
- `imds_support = "v2.0"` on the AMI and `http_tokens = "required"` on every
  instance (jumphost, control plane, GPU) require the IMDSv2 session token.
- `ena_support = true` on the AMI. The default and recommended instance
  families (`m7i`, `c6i`, `g5`, `p4d`, `p5`) use the Elastic Network Adapter.
- `vpc_mtu` defaults to 9001 (the VPC jumbo-frame MTU); the pod MTU is
  `vpc_mtu - 50`.

## x86_64 only

`elemental customize` builds x86_64 images. The jumphost, control-plane and GPU
instance types must be x86_64 families, and `jumphost_image` must be an x86_64
AMI.

## Image import

The jumphost uploads the raw image to a private, SSE-S3 encrypted S3 bucket
(`images/` prefix). Terraform then runs `aws_ebs_snapshot_import` and
`aws_ami`. Consequences:

- The jumphost role can list and write `images/*` only and holds no EC2
  permissions. The import runs as the `<cluster_name>-vmimport` role (or
  `vmimport_role_name`, see [Pre-created IAM](#pre-created-iam)), which the
  import service assumes with `sts:ExternalId = "vmimport"`.
- The identity running Terraform needs `iam:PassRole` on that role.
- `modules/aws/scripts/wait-for-raw.sh` runs on the workstation during apply and polls S3
  through the AWS CLI, so the CLI must be installed there.
- The raw image expires from S3 one day after upload unless
  `keep_build_artifacts = true`. Nodes read nothing from S3; the jumphost gets
  its script and config inline in `user_data`.
- The AMI and its snapshot are Terraform resources: `terraform destroy`
  removes them. `image_id` skips the build and must not name an AMI this
  module registered, because destroy or the apply that sets it deregisters
  that AMI. Copy it first (`aws ec2 copy-image`).

Rationale for the S3 existence check and hook layout:
[ADR 002](../decisions/002-aws-factory-hooks.md).

## IAM

- The module creates two IAM roles (`<cluster_name>-vmimport`,
  `<cluster_name>-jumphost`), their inline policies and the
  `<cluster_name>-jumphost` instance profile. The identity running Terraform
  needs IAM write permissions for them, plus `iam:PassRole`. The
  `AWSPowerUserAccess` managed policy excludes IAM actions, so it is not
  enough.
- IAM names are account-wide, not regional: two clusters with the same
  `cluster_name` in one account collide, even in different regions. Pick a
  `cluster_name` unique in the account.
- `deploy.sh` checks `iam:CreateRole` before planning (a `CreateRole` call
  with an invalid trust policy, which creates nothing) and stops on
  `AccessDenied`. It does not run for `--destroy` or when the IAM names are
  pre-created. Running `terraform` directly skips the check.

### Pre-created IAM

Accounts where the deployer cannot create IAM roles (for example
`AWSPowerUserAccess`) use roles an administrator creates once. Set both
variables (default `null`; setting only one fails at plan):

```hcl
vmimport_role_name             = "aif-precreated-vmimport"
jumphost_instance_profile_name = "aif-precreated-jumphost"
```

The module then creates no `aws_iam_*` resource and reads the role and profile
with data sources. `deploy.sh` skips its `iam:CreateRole` check when both are
set in the var files, `TF_VAR_*` or `-- -var`; it does not read `-- -var-file`
or `*.auto.tfvars`. Pick names that do not start with `<cluster_name>-`: the
module's own roles use that prefix, and `tools/leftovers/aws.sh` reports such roles after a
destroy. The build bucket is named `<cluster_name>-build-<random hex>`; the
policies below cannot know the suffix, so they match `<cluster_name>-build-*`.
One role pair can serve several clusters: replace `CLUSTER-build-*` with a
wildcard that covers all of them (for example `*-build-*`), or create one pair
per cluster.
Replace `CLUSTER` with the `cluster_name` and `ACCOUNT_ID` with the account ID.
The permissions equal what the module grants its own roles, except for that
bucket-name wildcard.

Write the documents:

```bash
cat >vmimport-trust.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AllowVmieToAssume",
    "Effect": "Allow",
    "Principal": {"Service": "vmie.amazonaws.com"},
    "Action": "sts:AssumeRole",
    "Condition": {"StringEquals": {"sts:ExternalId": "vmimport"}}
  }]
}
JSON

cat >vmimport-policy.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "BucketDiscovery",
      "Effect": "Allow",
      "Action": ["s3:GetBucketLocation", "s3:ListBucket"],
      "Resource": "arn:aws:s3:::CLUSTER-build-*"
    },
    {
      "Sid": "ReadRawImages",
      "Effect": "Allow",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::CLUSTER-build-*/images/*"
    },
    {
      "Sid": "Ec2ImportOperations",
      "Effect": "Allow",
      "Action": [
        "ec2:ModifySnapshotAttribute",
        "ec2:CopySnapshot",
        "ec2:RegisterImage",
        "ec2:Describe*"
      ],
      "Resource": "*"
    }
  ]
}
JSON

cat >jumphost-trust.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AllowEc2ToAssume",
    "Effect": "Allow",
    "Principal": {"Service": "ec2.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
JSON

cat >jumphost-policy.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListBucketImagesPrefix",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::CLUSTER-build-*",
      "Condition": {"StringLike": {"s3:prefix": "images/*"}}
    },
    {
      "Sid": "WriteRawImages",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:AbortMultipartUpload"],
      "Resource": "arn:aws:s3:::CLUSTER-build-*/images/*"
    }
  ]
}
JSON
sed -i.bak 's/CLUSTER/my-cluster/' vmimport-policy.json jumphost-policy.json && rm -f vmimport-policy.json.bak jumphost-policy.json.bak
```

Create the roles and the instance profile (the policy documents are inline, as
in the module):

```bash
aws iam create-role --role-name aif-precreated-vmimport \
  --assume-role-policy-document file://vmimport-trust.json
aws iam put-role-policy --role-name aif-precreated-vmimport \
  --policy-name aif-precreated-vmimport --policy-document file://vmimport-policy.json

aws iam create-role --role-name aif-precreated-jumphost \
  --assume-role-policy-document file://jumphost-trust.json
aws iam put-role-policy --role-name aif-precreated-jumphost \
  --policy-name aif-precreated-jumphost --policy-document file://jumphost-policy.json
aws iam create-instance-profile --instance-profile-name aif-precreated-jumphost
aws iam add-role-to-instance-profile \
  --instance-profile-name aif-precreated-jumphost --role-name aif-precreated-jumphost
```

The deployer needs `iam:PassRole` on both roles: the jumphost role when
`aws_instance` attaches the profile, the vmimport role when
`aws_ebs_snapshot_import` starts the import. The managed `AWSPowerUserAccess`
policy does not include it. Add this statement to the deployer's policy
(or permission set):

```json
{
  "Sid": "PassPrecreatedRoles",
  "Effect": "Allow",
  "Action": "iam:PassRole",
  "Resource": [
    "arn:aws:iam::ACCOUNT_ID:role/aif-precreated-vmimport",
    "arn:aws:iam::ACCOUNT_ID:role/aif-precreated-jumphost"
  ]
}
```

The data sources also call `iam:GetRole` (vmimport role) and
`iam:GetInstanceProfile` (jumphost profile), which `AWSPowerUserAccess` does
not include. Allow them on the vmimport role ARN and on
`arn:aws:iam::ACCOUNT_ID:instance-profile/aif-precreated-jumphost`.
`terraform destroy` does not remove the pre-created roles; delete them
separately when the cluster is gone.

## user_data limit

EC2 limits `user_data` to 16 KiB. The jumphost receives the factory script and
config tree gzip-compressed inside cloud-init, comments stripped, and a
precondition fails the plan when the rendered size exceeds the limit. Node
Ignition is gzip-compressed and size-checked the same way
(`user_data_max_bytes = 16384`).

## Jumphost AMI: Marketplace listing

The jumphost runs openSUSE Leap 16 (x86_64, publisher `679593333241`), an AWS
Marketplace listing. Behaviour:

- The account must accept the listing terms once:
  <https://aws.amazon.com/marketplace/pp?sku=51luq5gebk3opt7gcvkdrrm89>.
  `validate` and `plan` succeed without it; the apply fails at
  `aws_instance.jumphost` with `OptInRequired`, after the network, load
  balancers and IAM exist. Subscribe and re-apply; existing resources are
  reused.
- The listing restricts instance types. `m5`, `m6i`, `c5`, `c6i` and `t3`
  families were accepted in `eu-central-1` (2026-09-21); 7th-generation
  types return `UnsupportedOperation`. The default `jumphost_instance_type` is
  `c6i.xlarge`. Check a candidate with
  `aws ec2 run-instances --dry-run` (`DryRunOperation` means allowed).
  Control-plane, worker and GPU nodes boot the module's own AMI, which has no product
  code, so any family works there.
- The lookup filters on `architecture = x86_64` because the same publish run
  ships an arm64 image under the same name prefix.
- The current Leap 16 images carry a deprecation time, so the lookup sets
  `include_deprecated = true`; deprecated images still launch. Temporary, see
  [workarounds.md](../workarounds.md).
- `jumphost_image` (module variable) replaces the lookup with a specific AMI
  ID, for example a non-Marketplace image or an ID taken from
  <https://susepubliccloudinfo.suse.com/v1/amazon/REGION/images/active.json>.

## GPU quota and drivers

- A new account usually has a default vCPU quota of 0 for the GPU families.
  `ec2:RunInstances` then fails with `VcpuLimitExceeded` part-way through the
  apply. Terraform checks instance-type offerings per zone
  (`availability.tf`) but not quota: request the increase in Service Quotas
  before setting `gpu_pools`.
- Terraform checks that the zone offers the instance type, not that it has
  capacity. When it has none, `RunInstances` returns
  `InsufficientInstanceCapacity`. The message lists the region's other zones
  as alternatives; capacity there is not reserved and can be gone by the next
  apply. `modules/aws/scripts/check-and-reserve.sh --region <r>
  --max-cost-per-hour <usd> --zones <cluster zones>` tries NVIDIA GPU types
  cheapest first and holds the first available one with an open On-Demand
  Capacity Reservation (billed while unused, ends after `--hours`, default 2).
  Set the pool `instance_type` and `zone` it prints, re-apply, then cancel the
  reservation; the instance keeps running.
  Node instances use the `aws.nodes` provider with `max_retries = 3`, so the
  apply fails within minutes instead of retrying (see
  [workarounds.md](../workarounds.md)).
- The image has no DKMS. The GPU operator loads a precompiled driver
  container, which needs whole-GPU PCI passthrough; every GPU EC2 family
  (`p3`, `p4d`, `p5`, `g4dn`, `g5`, `g6`) provides it. The driver source is an
  interim override: see [workarounds.md](../workarounds.md).

## Storage

`image_disk_size` is the size of the raw image, not of the running disk. First
boot grows the root partition to the EBS volume. Root volumes are encrypted
gp3, sized by `control_plane_disk_size_gb`, `jumphost_disk_size_gb` and each
pool's `disk_size_gb` (default 200).

## Networking

- Nodes have private addresses only and reach the internet through one NAT
  gateway in the first public subnet. An S3 gateway endpoint carries S3
  traffic without the NAT gateway.
- A node's IP is fixed at plan time (host 20 and up of its zone's private
  subnet). EC2 reserves the first four addresses and the last one of each
  subnet.
- The internal NLB serves 6443 and 9345 inside the VPC. The internet-facing
  NLB serves 80/443 (proxy protocol v2 to Traefik) and 6443 from
  `api_cidrs`.
- `vpc_cidr` (default `10.20.0.0/20`) is split in two halves: the low half
  holds one public subnet per zone, the high half one private subnet per zone.
  It must not overlap the RKE2 pod and service CIDRs (10.42.0.0/16,
  10.43.0.0/16).
- Hostnames default to the NLB DNS names; set `rancher_hostname` and
  `api_host` to use your own DNS names. Nodes always reach the API through the
  internal NLB (`provider_details.internal_api_host`); `api_host` also
  replaces the public NLB name in the `api_host` output and the kubeconfig.

## Cost estimate

`make cost PROVIDER=aws TFVARS=...` estimates the cost from tfvars
([tools/cost](../../tools/cost/README.md)). Rates come from the AWS Price List
API, so it needs credentials with `pricing:GetProducts` (for example
`aws sso login`) and network access. It prices EC2 instances, gp3 volumes, the
NAT gateway with its public IPv4 address, load balancer hours, public IPv4
addresses and the image snapshot; the jumphost is listed as build only. Data
transfer, NLB capacity units, NAT per-GB processing and the raw image in S3 are
not included. The result is an estimate, not a quote.

## Tags and leftovers

Every taggable resource carries `elemental-cluster`, `elemental-managed-by`,
`elemental-module` and `elemental-created` (UTC `YYYYMMDD-hhmmss` of the first
apply for this cluster name, from `time_static`), plus `elemental-role` (what
the object is for: `control_plane`, `worker`, `gpu`, `agent`, `jumphost`,
`image`, `lb`, `network`, `iam`). Security groups and rules take the role of
what they protect. Nodes and their root volumes also carry `elemental-pool`
(`cp` for control planes). `elemental-build` (the `build_id`) is set on the
AMI, snapshot import, nodes and their root volumes only. Listeners and target
groups carry `elemental-listener` (the port name: `kube_api`, `supervisor`,
`http`, `https`). `var.tags` is merged in and must not use the `elemental-`
prefix.

## Leftover check

```bash
tools/leftovers/aws.sh <cluster_name> --region <region> [--all]
```

Read-only; `deploy.sh --destroy` prints the command at the end. It lists resources tagged
`elemental-cluster=<cluster_name>` from the Resource Groups Tagging API, which
is an index and keeps listing deleted resources for hours. Each ARN is therefore
confirmed with the owning service's describe call, and IAM roles and instance
profiles named `<cluster_name>-*` are listed (IAM is global and not in the
regional index). Status values:

- `LIVE`: the resource exists (terminated and deleted states count as gone).
- `RECORD`: import-snapshot task, a history entry that is not billed and expires.
- `UNKNOWN`: unsupported resource type, or a confirmation that failed for a
  reason other than "not found".

Exit 0 means nothing live or unknown, 1 something is, 3 the check was
inconclusive (credentials, list failure, `aws` missing).

Capacity reservations made by `check-and-reserve.sh` carry only
`elemental-managed-by=check-and-reserve`, no cluster tag, so the tool does not see
them. They are not cluster-scoped; list them with
`aws ec2 describe-capacity-reservations --filters Name=tag:elemental-managed-by,Values=check-and-reserve Name=state,Values=active`
and cancel them when done.

## Sources

- [VM Import/Export: importing a disk as a snapshot](https://docs.aws.amazon.com/vm-import/latest/userguide/vmimport-import-snapshot.html)
- [IMDSv2](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-metadata.html#instance-metadata-v2-how-it-works)
- [SUSE: GPU operators on RKE2](https://documentation.suse.com/cloudnative/rke2/latest/en/add-ons/gpu_operators.html)
- [NVIDIA: precompiled driver containers](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/precompiled-drivers.html)
