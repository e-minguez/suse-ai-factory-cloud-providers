# SUSE AI Factory on Vultr: example

Single-cluster root for [`modules/vultr`](../../modules/vultr/README.md): a
jumphost that builds the elemental image and imports it as a snapshot, three
`vpc_only` control-plane VMs behind an API load balancer and an ingress load
balancer, and optional GPU pools (bare metal, cloud, or both). `deploy.sh` runs
it in two passes. Platform notes: [`docs/providers/vultr.md`](../../docs/providers/vultr.md).

## Prerequisites

- Terraform 1.16.4 or later, `jq`, `curl`, `ssh`.
- A Vultr API key in `vultr_api_key` (for example in `../common-vultr.tfvars`).
  Terraform passes it to the provider and the wait scripts.
- Two different `openssl passwd -6` hashes: `root_password_hash` and
  `node_user_password_hash`.
- `ssh_authorized_keys` (at least one) and `admin_cidrs` (your IP or VPN range).
- Registry credentials: `appco_username`/`appco_password` with
  `local-path-provisioner` (default) or `suse-storage`; the others are optional.
  See [Registry credentials](../../README.md#registry-credentials).

## Quickstart

```bash
# Shared values (repo root, or examples/): every provider declares these.
cp ../../common-all.tfvars.example ../../common-all.tfvars   # edit

# Vultr-only values, optional: ../common-vultr.tfvars (vultr_api_key, region, ...)

cd examples/vultr
cp terraform.tfvars.example terraform.tfvars                 # edit REPLACE_WITH_*
./deploy.sh
```

Var files, later wins: `../../common-all.tfvars`, `../common-all.tfvars`,
`../common-vultr.tfvars`, `terraform.tfvars`. Only variables every provider
declares belong in `common-all.tfvars`.

`deploy.sh [--rebuild] [--yes] [-v|-q] [--destroy] [-- <terraform args>]`:
plan, list replacements and destroys, confirm, apply the saved plan; `--yes`
skips the question, `-v`/`-q` set verbosity, `--destroy` plans a destroy, and
arguments after `--` go to every `terraform plan`. Logs: `.deploy/logs/<ts>/`.

- Pass 1 "Create infrastructure": load balancers, jumphost, image build,
  snapshot import, nodes. It runs tens of minutes with little output; follow the
  build with `../../scripts/build-logs.sh`.
- Pass 2 "Attach load balancer backends": `deploy.sh` writes
  `pass2.auto.tfvars.json` from pass 1's `provider_details` and re-applies. It
  also closes the jumphost's tcp/80 rule. Keep the file, and use `./deploy.sh`
  rather than `terraform apply` after a node changes.
- The image is rebuilt only when the module's `build_hash` changes.
  `./deploy.sh --rebuild` bumps the counter in `rebuild.auto.tfvars.json` to
  force one; the old snapshot is deleted and every node is replaced. Do not set
  `image_rebuild` in tfvars.
- Both load balancers have no backends between the passes, and the ingress one
  stays unhealthy until Traefik answers `/ping`. Both are expected.

## After the deploy

From this directory (`next_steps` prints the same commands with absolute paths
and `-C`, usable from anywhere):

```bash
../../scripts/kubeconfig.sh -o ~/.kube/vultr.yaml    # admin credential, mode 600, no overwrite without --force
../../scripts/ssh.sh jumphost                        # or a name from `terraform output nodes`
../../scripts/ssh.sh <cluster>-cp-01                # then `su -` (node_username, no sudo)
../../scripts/build-logs.sh [--host NAME] [--no-follow]
terraform output next_steps
terraform output -raw rancher_bootstrap_password
```

Following the build during the apply with a remote backend:
[conventions](../../docs/conventions.md#following-a-build).

The `jumphost`, `nodes`, `api_host`, `rancher_url` and `egress_ips` outputs give
addresses. `tools/multicluster` can register this cluster in a Rancher
(`../../tools/multicluster/README.md`).

## GPU pools

`gpu_pools` defaults to `{}` (control plane only). `mdisk_mode` (`raid1`, `jbod`,
`none`) sets the managed disks of bare metal pools; `ssh_key_ids` adds Vultr SSH
keys to the jumphost and public-NIC nodes. `kind = "bare_metal"` takes a
`vbm-*` plan with a public NIC and no Vultr firewall; `kind = "vm"` (default)
takes a cloud plan, `public_ip = false` by default. `zone`, `disk_size_gb` and
`placement` must be null. Plans and stock checks are in the comments of `terraform.tfvars.example` and in
[`docs/providers/vultr.md`](../../docs/providers/vultr.md). Stock is checked at
plan time with one untyped availability query and a missing plan fails the plan.
Pools with `count = 0` are skipped, and so are pools whose nodes already exist
(same label, plan and region, looked up through the API), so a plan of a healthy
cluster does not fail when its last unit of stock is its own node. Adding a node
or changing a pool's plan re-enables the check. To find passthrough stock across
regions, run `../../tools/vultr/passthrough-stock.sh`.
Non-GPU plans (for example `vbm-6c-32gb-amd`, `voc-c-4c-8gb-150s-amd`) work as
stand-ins for testing the worker path.

## Troubleshooting

| Symptom | Cause and action |
|---|---|
| Plan fails with "Plans not available in region" | Out of stock, or an empty answer from a missing or invalid `vultr_api_key`. Check stock with the curl in `terraform.tfvars.example` or `../../tools/vultr/passthrough-stock.sh`. |
| "snapshot ... no longer exists", plans then fail with a 404 | Vultr's fetch failed and it deleted the record. `terraform state rm 'module.ai_factory.vultr_snapshot_from_url.ai_factory[0]'`, then `./deploy.sh`, or `--rebuild` if the jumphost stopped serving (`image_serve_seconds`, 1 h). |
| Waiting for the image never ends | Follow `../../scripts/build-logs.sh`. On the jumphost, `grep '\.raw' /var/log/elemental-factory.log` shows fetches; only your own address means the fetcher never connected. |
| `terraform plan` shows every node replaced after a bare `terraform apply` | Backends fell back to `[]`. Run `./deploy.sh`, and check `pass2.auto.tfvars.json` exists. |
| A lone `~ health_check { + path = "/" }` on the API load balancer | Provider default versus an empty API value; ignored by the module. |
| Node has no `/etc/rancher`, `rke2-server` inactive | Network hook failed. `journalctl -b \| grep configure-network`; the check in `modules/vultr/README.md`. |
| Bare metal node has no VPC address, second NIC `NO-CARRIER` | Host port not lit. Check `/sys/class/net/<if>/carrier` and `GET /v2/bare-metals/<id>/vpcs`; contact Vultr if the attachment exists. |
| Host reports `active` but never answers | Firmware boot mode of a reused bare metal host; `vultr-cli bare-metal vnc <id>`. |
| Longhorn PVC binds but the pod hangs in `ContainerCreating` | `systemctl status iscsi-prep.service iscsid` on the node. |
| local-path PVC `Pending`, `mkdir ... Permission denied` | `systemctl status local-path-prep.service`; `ls -ldZ /opt/local-path-provisioner` should be `container_file_t`. |
| `k8s-config-installer.service` "could not be found" | Expected: the unit removes itself on success. |
| Ingress backends all unhealthy | Health check is HTTP `/ping` on 8080 from the Traefik `HelmChartConfig`; never point it at 80/443 (PROXY header required). |
| Bare metal node answers on all ports | Vultr Firewall does not apply to bare metal; see the Security section of `docs/providers/vultr.md`. |

## Destroying

```bash
./deploy.sh --destroy
```

Plain `terraform destroy` needs the var files passed explicitly; see
[Running with plain Terraform](../../docs/manual-deploy.md#var-files);
every pass by hand: [docs/manual-deploy.md](../../docs/manual-deploy.md#vultr-2-passes).

The snapshot and the jumphost's port-80 rule are in state and are removed. Check
`vultr-cli bare-metal list` for bare metal servers left by interrupted runs.

After a successful `--destroy`, `deploy.sh` prints the read-only leftover check
command; it does not run it. Export the key first:

```bash
export VULTR_API_KEY=...   # same value as vultr_api_key
../../tools/leftovers/vultr.sh <cluster_name>
```

Expect `0 live`. It lists instances, bare metal servers, NAT gateways, load
balancers, VPC, firewall groups and snapshots of that cluster; it deletes nothing.
