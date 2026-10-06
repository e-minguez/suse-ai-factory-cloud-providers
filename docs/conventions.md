# Conventions shared by every provider

A provider module follows these rules, and a new provider does the same.
`make check-consistency` enforces the symlinks, the common variables in the
examples, the output set and the managed labels.

## Naming

| Concept | Variable |
|---|---|
| Cluster name | `cluster_name` |
| Control plane | `control_plane_instance_type`, `control_plane_disk_size_gb`, `control_plane_count`, `control_plane_public_ip` |
| Build host and bastion | `jumphost_instance_type`, `jumphost_disk_size_gb`, `jumphost_image`, `jumphost_username` |
| GPU and non-GPU workers | `gpu_pools`, `worker_pools` (one schema, see [scaling](scaling.md)) |
| Pinned image | `image_id`, or `image_ids` (map by zone) where images are per zone |
| Keep build artifacts | `keep_build_artifacts` |
| Network | `vpc_cidr` (subnets are derived from it), `vpc_mtu` |
| Extra labels | `tags` |
| Zones | `zones` (list of suffixes) |

Variables every provider declares live in one file,
`modules/common/variables-common.tf`. Terraform cannot import variable
declarations, so each provider module links to it with a symlink
(`modules/<p>/variables-common.tf`). Edit the original and run `make docs`.
Provider-specific limits on a common variable are `precondition` or `check`
blocks in the provider module, because a `validation` lives only in the
declaration. Provider-only variables stay in `modules/<p>/variables.tf`.

Variable descriptions are 1-2 sentences; detail goes to the module README.

### Variable files

`examples/<p>` declares only user-facing variables, the same common list in every
example, so `common-all.tfvars` (values shared by every provider) works with all
of them. `deploy.sh` layers `../../common-all.tfvars`, `../common-all.tfvars`,
`../common-<provider>.tfvars` and `terraform.tfvars`, later wins. Terraform
rejects a variable an example does not declare, so provider-only keys go in
`common-<provider>.tfvars` or `terraform.tfvars`.

"Later wins" applies to whole values: Terraform does not merge maps or lists
across files. A `tags` map in `terraform.tfvars` replaces the one in
`common-all.tfvars` or `common-<provider>.tfvars`, so repeat any shared keys
there. The managed `elemental-` labels are not affected (see [Labels](#labels)).

## Module boundaries

Shared: `elemental-config` (Elemental, RKE2 and Helm config, Ignition,
`build_hash`), `image-factory` (build script and provider hooks) and
`rke2-ports` (port tables). Per provider: network, load balancers, firewall,
compute, image delivery, the number of passes, `network/*.sh` and the
availability data sources. Examples name the module `ai_factory`.

## `gpu_pools` and `worker_pools`

One schema: `instance_type`, `count` (1), `disk_size_gb`, `zone`, `public_ip`
(false), `kind` (`vm` or `bare_metal`) and `placement`. Keys are 1-16 characters
of `[a-z0-9-]`, not `cp`; a `gpu_pools` key cannot be `worker` and a
`worker_pools` key cannot be `gpu` (both are `suse_storage_nodes` selectors), and
the keys differ between the two maps. Hostnames are `<cluster_name>-<pool>-NN`
(at most 63 characters). A provider rejects with a precondition the fields it
cannot honour: aws `public_ip = true`, `placement` and `kind = "bare_metal"`;
vultr `zone`, `disk_size_gb` and `placement`; evroc `kind = "bare_metal"`;
exoscale `zone`, `placement` and `kind = "bare_metal"` (`public_ip` has no
effect there: every node has a public IPv4, [ADR 008](decisions/008-exoscale-module.md)).

Exception: exoscale control planes are one instance pool, whose members
Exoscale names `<cluster_name>-cp-<5 characters of the pool ID>-<random>`
instead of `<cluster_name>-cp-NN` ([ADR 008](decisions/008-exoscale-module.md)).

## Labels

Every resource that can carry labels gets the same keys on every provider
(Vultr stores them as `key=value` strings in `tags`). Values follow Kubernetes
label value rules. `var.tags` is merged on top of the managed keys and must
not use the `elemental-` prefix. Keys contain no `/`, because the evroc API
rejects it; on evroc `var.tags` keys cannot contain `/` either.

| Key | On | Value |
|---|---|---|
| `elemental-cluster` | everything | `cluster_name` |
| `elemental-managed-by` | everything | `terraform` |
| `elemental-module` | everything | `ai-factory` |
| `elemental-created` | everything | UTC `YYYYMMDD-hhmmss` of the first apply |
| `elemental-role` | everything | one of the roles below |
| `elemental-pool` | nodes and per-node objects (disks, public IPs) | pool name; `cp` for control planes |
| `elemental-build` | objects whose content one build rewrites: image, snapshots, image-target disks, node disks, nodes | `build_id`; not on build hosts or long-lived infrastructure |
| `elemental-listener` | per-port load balancer objects | port name from `modules/rke2-ports` (`kube_api`, `supervisor`, `http`, `https`, ...) |

Role vocabulary: `control_plane`, `worker`, `gpu` (nodes and their per-node
objects, as `nodes[*].role`); `agent` (objects shared by worker and GPU nodes,
such as their security group); `jumphost` (SSH entry host, including a host that
also builds the image); `builder` (dedicated build VMs); `image` (image,
snapshots, image-target disks, raw-image bucket); `lb` (load balancers, their
listeners, target groups and VIPs); `network` (VPC, subnets, NAT, routes);
`iam`. Security groups take the role of what they protect. No other keys, apart
from the aws `Name` tag, a platform convention. Some Exoscale types carry no
labels at all (security groups, anti-affinity groups, templates); they are
named `<cluster_name>-<suffix>` and found by name.

## Outputs

Every provider module and every example exposes the same outputs with the same
types. A concept a provider does not have is `null`, not a missing output.
Outputs are data: actions live in `scripts/`, which read them. The one text
output is `next_steps`. Provider-only data goes in `provider_details`.

| Output | Type | Notes |
|---|---|---|
| `provider` | string | `aws`, `evroc`, `exoscale` or `vultr`; tools dispatch on it |
| `cluster_name`, `region` | string | |
| `kubernetes_api_endpoint` | string | `https://<api_host>:6443` |
| `api_host` | string | DNS name of the API for kubectl |
| `api_vip` | string | address baked into the nodes as `network.apiVIP` |
| `ingress_endpoint` | string or null | `https://...` of the ingress; null with `ingress_controller = "none"` |
| `rancher_url`, `rancher_hostname` | string or null | null when `rancher` is not in `components` |
| `rancher_bootstrap_password` | string, sensitive | null without Rancher |
| `jumphost` | object | `{ public_ip, private_ip, ssh_user }`; IPs are null when `image_id` is set and no jumphost exists |
| `nodes` | map(object) | key = hostname; `{ role, pool, init, zone, private_ip, public_ip, instance_type, id, ssh_user }`; `role` is `control_plane`, `worker` or `gpu`; `ssh_user` is `node_username` |
| `image` | object | `{ build_id, rebuild, ids }`; `rebuild` is the `image_rebuild` counter; `ids` maps region or zone to image ID, empty until the image exists |
| `egress_ips` | list(string) | public source IPs of cluster egress, used for allow-lists in [multicluster](../tools/multicluster/README.md#network) |
| `network` | object | `{ vpc_cidr, subnet_cidrs }` |
| `build_status` | object or null | `{ method, url_or_key, hosts }` while a build runs, null once the image exists; `scripts/build-logs.sh` follows `hosts` |
| `next_steps` | string | post-deploy hints printed by `deploy.sh` |
| `provider_details` | object | everything else; contents differ per provider and are documented in `docs/providers/<p>.md` |

`rke2_token` is not an output. It stays in state through `user_data`; see
[security](security.md).

Examples re-export the module outputs one to one, in an identical `outputs.tf`.

## Scripts and tools read outputs only

`scripts/kubeconfig.sh`, `scripts/ssh.sh`, `scripts/build-logs.sh` and
`tools/multicluster` use only the outputs above, so they work on every provider
and across providers. Usage is in the [README](../README.md#quickstart).

## Ignition and scripts

Static Ignition files hold only configuration that is valid at first boot.
Anything that depends on runtime state (network, NICs, sysext binaries) is a
script written by Ignition and run by a systemd oneshot unit or an elemental
initrd hook.

## Deploy script

`examples/<p>/deploy.sh [--rebuild] [--yes] [-v|-q] [--destroy] [-- <tf args>]`
only defines passes; `scripts/lib/tf.sh` and `scripts/lib/deploy-common.sh` do
the rest. Each pass runs `plan -out`, shows replacements and destroys, asks for
confirmation (unless `--yes`), then applies the saved plan with `apply -json`,
rendered by `jq`. `-v` streams plain Terraform output, `-q` prints step headers,
diagnostics and the summary, and without a TTY it prints one line per finished
resource group. On failure it prints the diagnostics, the last 30 log lines and
the log path. Logs are in `.deploy/logs/<ts>/`. It needs `terraform`, `jq` and
`ssh`. A new provider starts from `examples/aws/deploy.sh`, the smallest.

## Following a build

`scripts/build-logs.sh` follows the build log on the hosts in the `build_status`
output. During the apply the outputs are not in the state file yet, so it reads
`terraform_data.build_access` from state. A remote backend writes state at most
every `TF_STATE_PERSIST_INTERVAL` (20 s) on a resource completion, so with one
that entry can be missing until the build ends.

## Style

Comments say what and a non-obvious constraint, in about 3 lines; rationale goes
to an [ADR](decisions/README.md). No cross-provider comparisons in provider
code. State platform behaviour as fact and the choice that follows; upstream
defects link their issue and go in [workarounds](workarounds.md).

Diagrams live in [architecture.md](architecture.md), in Mermaid. They show roles
and main resource types, not individual resources or conditions, so a refactor
only touches them when a pass, a role or a traffic path changes.

## Adding a provider

1. `modules/<p>` with the standard files (`availability.tf`, `build.tf`,
   `image.tf`, `control-plane.tf`, `agent-nodes.tf`, `network.tf`,
   `loadbalancer.tf`, `firewall.tf`, `locals.tf`, `outputs.tf`,
   `variables.tf`, `versions.tf`), the `variables-common.tf` symlink, the
   shared modules, the managed labels and the output set above.
2. Every build input goes into `build_hash` through `elemental-config`
   (`extra_build_inputs` for inputs the provider owns), so a changed input
   rebuilds the image.
3. Availability and quota checks fail the plan (preconditions or
   postconditions, not warning `check` blocks).
4. `examples/<p>` with the common variables, `outputs.tf`, a
   `terraform.tfvars.example` and a `deploy.sh` that only defines passes
   and a `deploy_after_destroy` hook that prints the leftover check command.
5. `docs/providers/<p>.md` for platform behaviour, and an entry in
   `docs/workarounds.md` for each upstream defect worked around.
6. `terraform test` with `mock_provider`, and `ignition.platform.id` in
   `kernel_cmdline`.
7. `tools/leftovers/<p>.sh` on `scripts/lib/leftovers.sh`: lists the
   cluster's objects by `elemental-cluster` (or exact name where the platform
   has no labels), read-only, same output and exit codes, with a test using a
   fake CLI.
8. `tools/cost/internal/provider/<p>`: `defaults.go` mirrors the `coalesce`
   defaults in `modules/<p>/locals.tf` (locked by `TestDefaultsMatchLocals`),
   plus `Resolve`, `Expand` and a price catalog; register it in
   `internal/provider/all`. Add a golden test against
   `examples/<p>/terraform.tfvars.example` and a "Cost estimate" section to
   `docs/providers/<p>.md`.
