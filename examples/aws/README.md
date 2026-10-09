# SUSE AI Factory cluster on AWS

Single-cluster root for `modules/aws`: a jumphost instance that builds the
elemental image and imports it as an AMI, `control_plane_count` control-plane
nodes and optional GPU pools in private subnets behind two NLBs. One
`deploy.sh` run, one apply. Architecture: [modules/aws](../../modules/aws/README.md);
platform behaviour: [aws.md](../../docs/providers/aws.md).

## Prerequisites

- Terraform >= 1.16.5, `jq`, `ssh`, and the **AWS CLI on the workstation**
  (`modules/aws/scripts/wait-for-raw.sh` polls S3 with it during the apply).
- AWS credentials in the usual chain (`AWS_PROFILE`, environment, SSO); see
  [AWS credentials](#aws-credentials).
- IAM permissions: the module creates IAM roles and an instance profile named
  `<cluster_name>-*`, so `AWSPowerUserAccess` is not enough. IAM names are
  account-wide: use a `cluster_name` unique in the account. `deploy.sh` checks
  `iam:CreateRole` before planning. See
  [aws.md](../../docs/providers/aws.md#iam). Without IAM permissions, set
  `vmimport_role_name` and `jumphost_instance_profile_name` to roles an
  administrator created ([aws.md](../../docs/providers/aws.md#pre-created-iam)).
- The openSUSE Leap 16 Marketplace listing accepted once per account
  (<https://aws.amazon.com/marketplace/pp?sku=51luq5gebk3opt7gcvkdrrm89>).
  Without it the apply fails at `aws_instance.jumphost` with `OptInRequired`.
  See [aws.md](../../docs/providers/aws.md#jumphost-ami-marketplace-listing).
- Registry credentials: `appco_username`/`appco_password` with
  `local-path-provisioner` (default) or `suse-storage`; the others are optional.
  See [Registry credentials](../../README.md#registry-credentials).
- For `gpu_pools`: a vCPU service-quota increase for the instance family.

## AWS credentials

The provider block sets only `region`; credentials come from the standard AWS
SDK chain (environment → `AWS_PROFILE`/`~/.aws/config` → instance role).

SSO (IAM Identity Center):

```bash
aws configure sso --profile ai-factory   # once: SSO start URL, region, account, role
aws sso login --profile ai-factory       # each time the token expires (typically 8-12h)
export AWS_PROFILE=ai-factory
```

Static access keys:

```bash
aws configure --profile ai-factory       # access key id + secret
export AWS_PROFILE=ai-factory
# or: export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... [AWS_SESSION_TOKEN=...]
```

Check with `aws sts get-caller-identity`; `deploy.sh` runs it when the CLI
exists. Export `AWS_PROFILE` in the shell that runs `deploy.sh`: the
`wait-for-raw.sh` provisioner calls the AWS CLI with the same environment.

`No valid credential sources found` with `refresh cached SSO token failed ...
InvalidGrantException` means the SSO session expired: run `aws sso login
--profile <profile>`. If it persists right after a login, clear the cached
token (`rm -rf ~/.aws/sso/cache ~/.aws/cli/cache`) and log in again.

## Quickstart

Values are layered, later wins: `common-all.tfvars` (repo root or `examples/`),
`examples/common-aws.tfvars`, then `terraform.tfvars` here. Only files that
exist are used. `common-all.tfvars` holds what every provider declares
(`admin_cidrs`, SSH keys, password hashes, registry credentials); see
`common-all.tfvars.example` at the repo root. Put AWS-only values such as
`region` in `common-aws.tfvars` or `terraform.tfvars`.

```bash
cd examples/aws
cp terraform.tfvars.example terraform.tfvars   # replace every REPLACE_WITH_* value
./deploy.sh
```

Never commit these files. The hashes in `root_password_hash` and
`node_user_password_hash` (`openssl passwd -6`) must differ. Changing any
value baked into the image (keys, hashes, `components`, `aif_release`, ...)
builds a new image and replaces every node.

`deploy.sh [--rebuild] [--yes] [-v|-q] [--destroy] [-- <terraform plan args>]`

| Flag | Effect |
|---|---|
| `--rebuild` | Bump `image_rebuild` in `rebuild.auto.tfvars.json` to force a new image. Do not set `image_rebuild` in `terraform.tfvars`. |
| `--yes` | Skip the confirmation (required without a terminal). |
| `-v` / `-q` | Full Terraform output / headers and summary only. |
| `--destroy` | Plan and apply a destroy. |
| `-- ...` | Passed to `terraform plan`. |

It plans, lists replacements and destroys, asks for confirmation and applies
the saved plan. Logs go to `.deploy/logs/<timestamp>/`. A cold run takes
roughly 30 to 60 minutes; the image build and snapshot import are the long
part, and the charts finish reconciling a few minutes after the apply returns.

## Access

Run from this directory (or pass `-C DIR`). Nothing here runs automatically.
`next_steps` prints the same commands with absolute paths and `-C`, usable
from anywhere.

```bash
terraform output next_steps

../../scripts/kubeconfig.sh -o ~/.kube/<cluster_name>.yaml   # admin credential, mode 600
../../scripts/ssh.sh jumphost                                # build host and SSH bastion
../../scripts/ssh.sh <node>                                  # names: terraform output nodes
../../scripts/build-logs.sh                                  # follow the image build, also during the apply
```

During the apply `build-logs.sh` reads `terraform_data.build_access` from
state; with a remote backend the entry can be missing until the build ends
([modules/aws](../../modules/aws/README.md#image-pipeline)).

- The jumphost login is `jumphost_username` (default `suse`, passwordless
  sudo). Nodes use `node_username`; the image has no sudo, so run `su -` with
  the root password. `permit_root_ssh = true` is a debug toggle.
- `kubeconfig.sh` writes `server: https://<api_host>:6443`. The `api_host`
  output defaults to the public NLB, whose 6443 listener accepts `api_cidrs`
  (default `0.0.0.0/0`); from elsewhere, run `kubectl` on a node. Nodes reach the API through
  the internal NLB (`provider_details.internal_api_host`).
- `rancher_url` and `rancher_bootstrap_password` are outputs:
  `terraform output -raw rancher_bootstrap_password`.

Quick checks:

```bash
kubectl get nodes -o wide          # control_plane_count + GPU nodes Ready
kubectl get helmcharts -A          # every chart job Complete
```

To register this cluster in a Rancher management cluster, see
[`tools/multicluster`](../../tools/multicluster/README.md).

## Reusing an image

`image_id` boots an existing AMI and skips the jumphost. It must not be an AMI
this module registered. Copy it before destroying the stack:

```bash
aws ec2 copy-image --source-region <region> --region <region> \
  --source-image-id "$(terraform output -json image | jq -r '.ids[]')" --name <cluster_name>-keep
```

`ssh.sh` (it reaches nodes through the jumphost) and `build-logs.sh` need the
jumphost, so they are unavailable while `image_id` is set.

## Teardown

```bash
./deploy.sh --destroy
../../tools/leftovers/aws.sh <cluster_name> --region <region>   # read-only; expect "0 live, 0 unknown"
```

Plain `terraform destroy` needs the var files passed explicitly; see
[Running with plain Terraform](../../docs/manual-deploy.md#var-files);
every pass by hand: [docs/manual-deploy.md](../../docs/manual-deploy.md#aws-1-pass).

The AMI, its snapshot and the build bucket are removed with the stack.

Capacity reservations from `check-and-reserve.sh` are not cluster-scoped and are not listed by the tool:
`aws ec2 describe-capacity-reservations --filters Name=tag:elemental-managed-by,Values=check-and-reserve Name=state,Values=active`, then cancel them.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `OptInRequired` on `aws_instance.jumphost` | Marketplace listing not accepted. Subscribe and re-apply. |
| `InsufficientInstanceCapacity` on `aws_instance.agent` or `aws_instance.control_plane` | No capacity for the instance type in that zone. For GPU pools, `../../modules/aws/scripts/check-and-reserve.sh --region <region> --max-cost-per-hour <usd> --zones <zones>` reserves the cheapest available type; set the pool `instance_type` and `zone` it prints and re-apply. Otherwise change `zone` (or `zones` for control planes) and re-apply. |
| `UnsupportedOperation` on `aws_instance.jumphost` | `jumphost_instance_type` is a family the listing rejects (for example `m7i`). Use `c6i.xlarge`. |
| `no matching AMI found` at plan | The listing is not found in the region. Set the module's `jumphost_image` to an AMI ID (add it to this root's `variables.tf` and `main.tf`). |
| `VcpuLimitExceeded` on a GPU node | vCPU quota is 0 for the family. Request an increase in Service Quotas, then re-apply. |
| `Instance type ... is not offered in <zone>` | Choose another type or zone. |
| `wait-for-raw.sh` "command not found" | The AWS CLI is not on the workstation `PATH`. |
| Apply waits over 90 minutes for the raw image | Stalled build. Run `../../scripts/build-logs.sh`; usual cause is a slow `podman pull` or manifest fetch. |
| `ExpiredToken` / `No valid credential sources` | Refresh credentials (`aws sso login --profile <profile>`). |
| `kubeconfig.sh` or `ssh.sh` fails | `image_id` is set (no jumphost) or `deploy_nodes = false` (no nodes). |
| `deploy.sh` stops with "cannot create IAM role" | The identity lacks `iam:CreateRole`/`iam:TagRole`. Use an identity with IAM permissions, or pre-create the roles ([aws.md](../../docs/providers/aws.md#pre-created-iam)). |
| `must both be set or both be null` at plan | Only one of `vmimport_role_name` and `jumphost_instance_profile_name` is set. Set both or neither. |
| `AccessDenied` on `iam:PassRole`, `iam:GetRole` or `iam:GetInstanceProfile` | The deployer's policy lacks the statements listed under [Pre-created IAM](../../docs/providers/aws.md#pre-created-iam). |
| `--rebuild` refuses to run | `image_rebuild` is set in a tfvars file. Remove it. |
