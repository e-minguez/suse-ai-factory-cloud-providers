# SUSE AI Factory on evroc: example

Single-cluster root for [`modules/evroc`](../../modules/evroc/README.md): one
build host per zone builds the elemental image for its zone, three control-plane
VMs (one per zone) boot clones of it behind one load balancer (API, supervisor
and ingress on one public IP), and optional worker and GPU pools join as agents.

Platform behaviour behind the design (passes, zonal snapshots, quota, GPU
rules): [`docs/providers/evroc.md`](../../docs/providers/evroc.md). Variables
and outputs: [`modules/evroc/README.md`](../../modules/evroc/README.md).

## Prerequisites

- Terraform 1.16.5 or later.
- `jq` and `ssh`. `curl` is used by the build-status commands below.
- `evroc login`, which writes `~/.evroc/config.yaml`. The provider block is
  empty and reads credentials, region and project from that file. `deploy.sh`
  stops if the file is missing.
- Registry credentials: `appco_username`/`appco_password` with
  `local-path-provisioner` (default) or `suse-storage`; the others are optional.
  See [Registry credentials](../../README.md#registry-credentials).
- Quota for the shape you choose. The default (3 zones, `a1a.m` build hosts,
  3 x `c1a.m` control planes, no node public IPs) fits a default project;
  GPU pools need a GPU quota increase. The plan fails early if the cluster's
  footprint exceeds the organization quota limit.

## Quickstart

```bash
# values shared by every provider (repo root, gitignored)
cp common-all.tfvars.example common-all.tfvars      # edit

cd examples/evroc
cp terraform.tfvars.example terraform.tfvars        # edit the REPLACE_WITH_* values
evroc login

./deploy.sh
```

`deploy.sh` reads var files in this order, later wins, only those that exist:
`../../common-all.tfvars`, `../common-all.tfvars`, `../common-evroc.tfvars`,
`terraform.tfvars`. `common-all.tfvars` may only set variables every provider
declares; evroc-only settings (`zones`, `project`, ...) go in
`common-evroc.tfvars` or `terraform.tfvars`.

Interface: `deploy.sh [--rebuild] [--yes] [-v|-q] [--destroy] [-- <terraform plan args>]`.
Each pass is planned, summarised (adds, changes, replacements, destroys) and
confirmed before it is applied; `--yes` skips the question and is required
without a terminal. `-v` streams the full Terraform output, `-q` prints only
headers and diagnostics. Logs are in `.deploy/logs/<timestamp>/`. `deploy.sh`
runs `terraform init` itself.

After the apply it prints how to fetch access, with absolute paths and `-C`, so
the commands work from anywhere. It runs none of these itself. From this directory:

```bash
../../scripts/kubeconfig.sh -o ~/.kube/<cluster>.yaml   # admin credential, mode 600
../../scripts/ssh.sh jumphost                           # or a hostname from `terraform output nodes`
../../scripts/build-logs.sh                             # follow the image build (pass 1)
```

`ssh.sh` logs in as `node_username` (no sudo; use `su -`) through the jumphost.
`kubeconfig.sh` without `-o` prints to stdout; `-o` refuses to overwrite an
existing file without `--force`.

## Passes

| Pass | Header in `deploy.sh` | Result |
|---|---|---|
| 1 | Build image | Network, load balancer, build hosts, blank image disks. Blocks for tens of minutes while the zones build in parallel. |
| 2 | Create nodes | Detaches the disks, snapshots each zone's disk, creates control-plane, worker and GPU nodes. |
| 3 | Reclaim build disks | Deletes the image-target disks. Skipped in effect when `keep_build_artifacts = true`. |

With snapshots already in state, `deploy.sh` runs one pass. `--rebuild` bumps
the persisted rebuild counter (`rebuild.auto.tfvars.json`; do not set
`image_rebuild` in `terraform.tfvars`), runs pass 1 again and replaces every
node ([ADR 003](../../docs/decisions/003-rebuild-counter.md)). Run it after any
change to an image input: credentials or keys baked into the image,
`components`, `aif_release`, `gpu_driver_*`, `permit_root_ssh`, `node_username`,
`elemental_image`, `core_platform_override`, `sysext_image_overrides`,
`image_disk_size`, `fips`. Node-only changes (`gpu_pools`, sizing,
`admin_cidrs`, `ingress_cidrs`) need no rebuild.

Pass 2 writes `pass2.auto.tfvars.json` so a later bare `terraform apply` keeps
`image_ready = true`.

Watch pass 1 from another terminal:

```bash
../../scripts/build-logs.sh                    # every build host
../../scripts/build-logs.sh --host <name|ip>   # one host, from the build_status output
curl "$(terraform output -json build_status | jq -r .url_or_key)"   # one status line per zone
```

The status URL is readable from `admin_cidrs` addresses only.

## Post-deploy checks

```bash
export KUBECONFIG=~/.kube/<cluster>.yaml
kubectl get nodes -o wide
terraform output nodes          # one control plane per zone
terraform output image          # one snapshot id per zone
terraform output -raw rancher_url
terraform output -raw rancher_bootstrap_password
kubectl get pods -n gpu-operator                    # if gpu_pools is set
```

GPU pools: an unpinned pool uses `zones[0]`, which must be zone `a`
(the platform admits GPU VMs there only). Do not reorder `zones` on a standing
cluster: subnets are numbered by position.

## Several clusters and Rancher registration

Use [`tools/multicluster`](../../tools/multicluster/README.md): `cluster.sh new
evroc <name>` creates a directory of symlinks to this example, and `cluster.sh
register <mgmt> <downstream...>` imports downstream clusters into the
management cluster's Rancher. Its `ingress_cidrs` must include the downstream
`egress_ips`.

## Teardown

```bash
./deploy.sh --destroy
```

Plain `terraform destroy` needs the var files passed explicitly; see
[Running with plain Terraform](../../docs/manual-deploy.md#var-files);
every pass by hand: [docs/manual-deploy.md](../../docs/manual-deploy.md#evroc-3-passes).

Snapshots and disks are Terraform-owned, so destroy removes them. Afterwards
`terraform state list` is empty; delete `pass2.auto.tfvars.json` and
`rebuild.auto.tfvars.json`.

`deploy.sh --destroy` ends by printing the read-only leftover check command; it
does not run it:

```bash
../../tools/leftovers/evroc.sh <cluster_name> [--region <region>]
```

Expect `0 live`. It needs the `evroc` CLI and its login.

## Troubleshooting

| Symptom | Cause | Action |
|---|---|---|
| VM `Running`, nothing answers | Missing UEFI label, or the image did not boot; there is no console | [evroc.md](../../docs/providers/evroc.md#there-is-no-console); keep `keep_build_artifacts = true` to inspect the disk |
| Plan proposes replacing every node | `image_ready` reverted to `false` (snapshots planned for destroy) | Check `pass2.auto.tfvars.json` has `"image_ready": true`; re-run `./deploy.sh`. Do not set `image_ids` to the module's own snapshots |
| Pass 2 plan shows `terraform_data.image_written must be replaced` | An image input changed between passes | Do not approve. Re-run `./deploy.sh --rebuild` |
| Pass 1 reports a zone as `unreachable` | The address Terraform runs from is not in `admin_cidrs` | Add every egress address of that machine and re-run; the build continues |
| Pass 1 fails with `failed <build id> <step>` | A build step failed on one zone | `../../scripts/build-logs.sh --host <ip>` shows why; re-run `./deploy.sh --rebuild` |
| Pass 2: snapshot fails, disk still attached | Detach and snapshot in one apply | Re-run `./deploy.sh`; the detach already happened |
| Plan fails: "vCPU / Memory / Public IP quota: this cluster needs N ..." | The cluster footprint (peak over passes) exceeds the organization limit. Usage by other workloads is not checked | Smaller `jumphost_instance_type` and `control_plane_instance_type`, fewer zones, `control_plane_public_ip = false`, or a quota increase |
| Plan fails: "Requested flavors not offered" | Typo or withdrawn profile | The error lists the available profiles |
| `not enough quota ... nvidia.com/AD102GL_L40S` at apply | GPU quota is per model and counted in GPUs (flavor size x count) | Lower `count`, or ask evroc; compare `provider_details.gpu_quota_request` with your allowance |
| `cannot deploy a GPU VM in zone "b"` | GPU VMs run in zone `a` only | Pin the pool to `a` or list `a` first in `zones` (the plan checks this) |
| `Ready: disk is missing DiskImageRef` on a GPU VM | The project still enforces the older GPU boot-disk rule | Ask evroc; set `gpu_pools = {}` meanwhile |
| Create reports an object already exists, or a 409 survives the retries | An interrupted apply left objects outside state, or the `cluster_name` is used elsewhere | Run `../../tools/orphans/evroc`, review `orphan-imports.tf.proposed`, rename to `imports.tf`, re-run `./deploy.sh`, delete `imports.tf` afterwards. Or change `cluster_name` |
| Plan proposes replacing every subnet and node after editing `zones` | The list was reordered | Restore the order; append only |
| `kubectl` times out right after pass 2 | Backend pool not yet healthy | Wait a minute for RKE2 to listen; check `curl -k https://$(terraform output -raw api_vip):6443/readyz` |
| Nodes `Ready`, chart installs in `ImagePullBackOff` | Runtime egress blocked | `curl -sSf https://dp.apps.rancher.io/v2/` from a node |
| Large transfers hang, TLS handshakes stall | MTU mismatch | `cat /etc/cni/net.d/10-canal.conflist` on a node; the veth MTU is `vpc_mtu - 50` |

## Security

State holds every sensitive input in plaintext (password hashes, registry
credentials, NGC key, RKE2 join token, Rancher bootstrap password). Use an
encrypted remote backend and restrict access. The same values are baked into
the image, so the per-zone snapshots (and kept image-target disks) are
credentials too. Build hosts hold them in their unpacked config. See
[`docs/security.md`](../../docs/security.md).
