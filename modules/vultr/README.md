# `modules/vultr`

Terraform module for a SUSE AI Factory cluster on Vultr: a jumphost that
builds the elemental image and imports it as a snapshot, one or an odd number
of `vpc_only` control-plane VMs behind a load balancer that acts as the
Kubernetes API VIP, a second load balancer for the Traefik ingress, and any mix
of worker and GPU pools (bare metal, cloud, or both) in the same VPC.

The module builds its own snapshot: the jumphost runs `elemental customize --type
raw` in podman and serves the result over HTTP, Terraform imports it with
`vultr_snapshot_from_url` and waits for `complete` before creating nodes. The
snapshot is in state, so `terraform destroy` deletes it. The jumphost holds no
Vultr API key.

Platform behaviour and the reasons behind these choices:
[`docs/providers/vultr.md`](../../docs/providers/vultr.md). Runnable root and
`deploy.sh`: [`examples/vultr`](../../examples/vultr/README.md).

Shared pieces: `modules/elemental-config` (rendered config, per-node Ignition,
`build_hash`), `modules/image-factory` (build script), `modules/rke2-ports`
(firewall port tables). Common variables come from
`modules/common/variables-common.tf` through the `variables-common.tf` symlink;
provider-only variables are in `variables.tf`.

## Topology

```
        internet --> lb.api      --> 6443 api_cidrs, 9345 NAT gateway + public agent nodes only
        internet --> lb.ingress  --> 80/443 (proxy protocol), health check /ping:8080
                            |  both: vpc = the VPC, backends = the control planes
        internet --> jumphost    the only inbound admin path (ssh from admin_cidrs)
                            |
                     +------+----------------+-------------------------+
                  <cluster>-cp-01..NN   <cluster>-<pool>-NN      <cluster>-<pool>-NN
                  vpc_only + NAT        kind = "bare_metal"      kind = "vm"
                  Traefik pinned here   public NIC, no firewall  firewalled, or vpc_only
```

Worker pools (`worker_pools`, no GPU) and GPU pools (`gpu_pools`) use the same
schema and the same resources; `kind` selects the resource family
(`vultr_bare_metal_server` or `vultr_instance`). Pool keys are unique across both
maps, and `nodes[*].role` is `worker` or `gpu`. Nodes are named
`<cluster_name>-<pool>-NN`; the name is the hostname Terraform sets and Ignition
writes to `/etc/hostname`, and `cp` is reserved for control planes. The ingress
load balancer exists only with `ingress_controller = "traefik"`.

Creation order:

```
1  vultr_vpc              original (non-VPC 2.0) VPC
2  vultr_nat_gateway      egress for vpc_only nodes
3  vultr_load_balancer    api and ingress; addresses read back through the API
4  jumphost               builds the image with the load balancer addresses baked in,
                          serves it on :80 for image_serve_seconds
5  snapshot               terraform_data.image_served polls the URL, then
                          vultr_snapshot_from_url, then poll until "complete"
6  control-plane nodes    vultr_instance, vpc_only
   worker and GPU nodes   vultr_bare_metal_server / vultr_instance
-- pass 2 (deploy.sh) -----------------------------------------------------
7  load balancer backends + rules, close tcp/80 (image_import_port_open = false)
```

## Two passes

The load balancer address is an input of the image, and the nodes boot from the
image, so `attached_instances` cannot reference the nodes in the same graph.
`lb_backend_instance_ids`, `lb_supervisor_extra_cidrs` and `agent_cloud_extra_cidrs`
are plain variables that default to `[]`; `deploy.sh` fills them from
`provider_details` (`control_plane_ids`, `agent_node_cidrs`,
`nat_gateway_public_cidrs`) in `pass2.auto.tfvars.json` and applies again. The
file is auto-loaded, so the values persist. Pass 1 keeps them, so a rerun without
changes plans nothing; it resets them when the plan deletes a node or the NAT
gateway, or creates the snapshot or a load balancer. A missing or reset file is
rebuilt from `provider_details` before pass 1. The reason for the
second pass is in [`docs/providers/vultr.md`](../../docs/providers/vultr.md#passes-2-and-why).

Load balancer addresses come from `data.http.lb` (Vultr API), not from
`vultr_load_balancer.*.ipv4`. The ids go through `terraform_data.lb_ids` so the
read stays at plan time on both passes. See
[`docs/providers/vultr.md`](../../docs/providers/vultr.md#load-balancers) and
[`docs/workarounds.md`](../../docs/workarounds.md).

## Ingress

`ingress_controller` (default `traefik`) becomes RKE2's `ingress-controller`.
`modules/elemental-config` renders a `HelmChartConfig` that pins the DaemonSet to
control-plane nodes (hostPorts 80/443/8080), trusts PROXY headers from `vpc_cidr`,
and exposes `/ping` on 8080 for the load balancer health check. The API and
ingress load balancers are separate because proxy protocol and health checks are
per load balancer. `rancher_hostname` defaults to
`rancher-<ingress load balancer IP>.sslip.io` and `api_host` to
`rke2-<api_vip>.sslip.io` (in the API certificate SANs); both are part of the
image.

## Nodes

One snapshot serves every node. Role and hostname arrive through per-node
Ignition `user_data` (`module.config.node_runtime_ignition`), so adding a pool or
node never rebuilds the image. Network setup that needs runtime state is two
scripts:

- `templates/elemental/network/configure-network.sh.tftpl` (initrd hook): reads
  Vultr metadata, counts physical NICs, sets MTU (`vpc_mtu`, default 1450) and
  disables IPv6. On a dual-NIC bare metal node it configures the VPC NIC through
  nmstate; a `vpc_only` NIC is left to DHCP.
- `write-node-ip.sh` (shared, first-boot unit, `enable_write_node_ip = true`):
  with several NICs, writes `99-node-ip.yaml` with the address inside `vpc_cidr`.

`journalctl -b | grep configure-network` is the first check on a node with no
`/etc/rancher`: elemental orders its RKE2 first boot behind that hook. Login is
`node_username` (default `suse`) with `su -`; the image has no sudo.

## What triggers an image rebuild

`module.config.build_hash` is the only trigger. It covers the rendered config
files, the release manifest body, `elemental_image`, `core_platform_override`,
the effective `sysext_image_overrides`, `image_rebuild`, and the factory script
(`extra_build_inputs`). Comments are stripped before hashing, so editing one does
not rebuild.

A new hash rotates `random_id.serve_path`, which replaces the jumphost and, through
`replace_triggered_by`, the snapshot and every node. The previous snapshot is
deleted. `deploy.sh --rebuild` bumps `image_rebuild`
([ADR 003](../../docs/decisions/003-rebuild-counter.md)).

- Changing SSH keys, password hashes, `permit_root_ssh`, `components`,
  `aif_release`, `ingress_controller` or anything moving a load balancer address
  rebuilds the image.
- A jumphost replaced for another reason does not rebuild the cluster: the
  snapshot ignores changes to `url`.
- `image_id` set skips the snapshot import (`count = 0`) and boots the nodes from
  that snapshot; the jumphost is still created.
- `deploy_nodes = false` builds the image only.

Design of the rendered files, `aif_release`, `components`, storage helper units
and the beta overrides (`core_platform_override`, `sysext_image_overrides`,
`gpu_driver_*`): [`modules/elemental-config`](../elemental-config/README.md),
[ADR 001](../../docs/decisions/001-elemental-config-rationale.md) and
[`docs/workarounds.md`](../../docs/workarounds.md).

## Availability and input checks

`data.http.plan_availability` checks stock at plan time with one untyped query for
the control-plane plan, the jumphost plan and every worker or GPU pool with `count > 0`
whose nodes do not all exist yet, and fails the plan naming the pool. Input checks
are preconditions on `vultr_vpc.this` (`zones` at
most one entry, `region` set, `control_plane_disk_size_gb`,
`jumphost_disk_size_gb` and `control_plane_public_ip` unchanged, unsupported
`gpu_pools` and `worker_pools` fields, `kind` against the `vbm-*` prefix).
`aif_release` is checked against the fetched manifest's `metadata.version` with a
warning only.

## Provider-only variables

| Variable | Purpose |
|---|---|
| `vultr_api_key` | Plan-time availability, load balancer address lookups and the wait scripts; the example root also passes it to the provider |
| `ssh_key_ids` | Vultr SSH key IDs for the jumphost and nodes with a public NIC |
| `mdisk_mode` | `raid1`, `jbod` or `none`; bare metal pools only |
| `lb_backend_instance_ids`, `lb_supervisor_extra_cidrs`, `agent_cloud_extra_cidrs`, `image_import_port_open` | Set by `deploy.sh` on pass 2 |

`provider_details` output: `control_plane_ids`, `agent_node_cidrs`,
`nat_gateway_public_cidrs`, `nat_gateway_private_ip`, `agent_cloud_firewall_group_id`,
`jumphost_vpc_ip`, `node_tags`.

## Inputs and outputs

Generated by `make docs`; do not edit between the markers.

<!-- BEGIN_TF_DOCS -->
## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| admin\_cidrs | CIDRs allowed to reach the jumphost and nodes over SSH. No default: an empty list locks everyone out. | `list(string)` | n/a | yes |
| agent\_cloud\_extra\_cidrs | Extra CIDRs allowed on the RKE2 ports of cloud agent nodes (GPU and worker pools), beyond the VPC CIDR. deploy.sh fills it from the nat\_gateway\_public\_cidrs value on pass 2. | `list(string)` | `[]` | no |
| aif\_release | AI Factory release: a manifest URL (http:// or https://), or a version X.Y.Z[-pre] resolved to the SUSE/aif tag aif-operator-<version>. | `string` | `"2.3.0"` | no |
| api\_cidrs | CIDRs allowed to reach the public Kubernetes API listener on 6443. Narrow it to keep kubectl access off the internet. | `list(string)` | <pre>[<br/>  "0.0.0.0/0"<br/>]</pre> | no |
| api\_host | DNS name of the RKE2 API, added to the API server certificate SANs. Null derives a provider default. | `string` | `null` | no |
| appco\_password | Application Collection password or token, paired with appco\_username. | `string` | `null` | no |
| appco\_registry | Registry host used by the Application Collection image pull secret. | `string` | `"dp.apps.rancher.io"` | no |
| appco\_username | Application Collection username. Required with local-path-provisioner or suse-storage; recommended with aif-operator so it can pull its workloads right after deployment. | `string` | `null` | no |
| cluster\_name | Prefix of resource names and node hostnames (<cluster\_name>-cp-NN, <cluster\_name>-<pool>-NN). | `string` | `"suse-ai-factory"` | no |
| components | AI Factory Helm charts to enable. Rendered in canonical order, not the order given. | `list(string)` | <pre>[<br/>  "rancher",<br/>  "gpu-operator",<br/>  "local-path-provisioner",<br/>  "aif-operator"<br/>]</pre> | no |
| control\_plane\_count | Number of control-plane nodes: 1 (single node, no etcd quorum) or odd and at least 3. Growing from 1 only adds nodes. | `number` | `3` | no |
| control\_plane\_disk\_size\_gb | Root disk size in GB of the control-plane nodes. Null uses the provider default; providers whose plans fix the disk reject a value. | `number` | `null` | no |
| control\_plane\_instance\_type | Machine type, flavor or plan of the control-plane nodes. Null uses the provider default (about 4 vCPU / 16 GiB). | `string` | `null` | no |
| control\_plane\_public\_ip | Give control-plane nodes a public IP. Not needed for access or egress on providers with NAT; providers that never assign one reject true. | `bool` | `false` | no |
| core\_platform\_override | Beta workaround: flatten the release manifest into a core platform manifest pinning these images; null disables it. See docs/workarounds.md. | <pre>object({<br/>    os_image_base      = string<br/>    os_image_iso       = string<br/>    kubernetes_version = string<br/>    kubernetes_image   = string<br/>  })</pre> | <pre>{<br/>  "kubernetes_image": "registry.suse.com/elemental/rke2/rke2-tar:1.35.6_rke2r1-9.1",<br/>  "kubernetes_version": "v1.35.6+rke2r1",<br/>  "os_image_base": "registry.suse.com/beta/uc/base-os-kernel-default:16.1-73.2",<br/>  "os_image_iso": "registry.suse.com/beta/uc/base-os-kernel-default-iso:16.1-73.3"<br/>}</pre> | no |
| deploy\_nodes | Provision control-plane, worker and GPU nodes. false builds the image only and creates no nodes. | `bool` | `true` | no |
| elemental\_image | Container image that runs `elemental customize` on the build host. | `string` | `"registry.suse.com/beta/uc/elemental:3.1.0-6.5"` | no |
| fips | Set cryptoPolicy: fips in install.yaml. Every node must be FIPS-ready. | `bool` | `false` | no |
| gpu\_driver\_repository | Registry path of the precompiled NVIDIA driver container. Experimental default; see docs/workarounds.md. | `string` | `"registry.opensuse.org/home/eminguez/branches/home/avicenzi/nvidia-for-bci-161/containerfile/third-party/nvidia"` | no |
| gpu\_driver\_version | NVIDIA driver branch of the precompiled driver container; must exist under gpu\_driver\_repository. | `string` | `"615"` | no |
| gpu\_pools | GPU worker pools keyed by pool name. instance\_type is the provider's type, flavor or plan; kind is vm or bare\_metal; fields a provider does not support must be null. | <pre>map(object({<br/>    instance_type = string<br/>    count         = optional(number, 1)<br/>    disk_size_gb  = optional(number)<br/>    zone          = optional(string)<br/>    public_ip     = optional(bool, false)<br/>    kind          = optional(string, "vm")<br/>    placement     = optional(string)<br/>  }))</pre> | `{}` | no |
| image\_disk\_size | Size of the raw image elemental builds (install.yaml raw.diskSize). | `string` | `"8G"` | no |
| image\_id | Existing image (AMI or snapshot) to boot instead of building one. Null builds the image. Providers with per-zone images use image\_ids. | `string` | `null` | no |
| image\_import\_port\_open | Allow tcp/80 from anywhere on the jumphost so Vultr can fetch the raw image. deploy.sh sets it to false on pass 2, once the snapshot is complete. | `bool` | `true` | no |
| image\_rebuild | Rebuild counter mixed into the image build hash. deploy.sh --rebuild bumps it in rebuild.auto.tfvars.json; do not set it by hand unless you know why. | `number` | `0` | no |
| ingress\_cidrs | CIDRs allowed to reach the ingress on 80/443, which serves the Rancher UI. Narrow it for clusters that are not public. | `list(string)` | <pre>[<br/>  "0.0.0.0/0"<br/>]</pre> | no |
| ingress\_controller | RKE2 ingress-controller setting. Only traefik adds a HelmChartConfig. | `string` | `"traefik"` | no |
| jumphost\_disk\_size\_gb | Root disk size in GB of the jumphost. Null uses the provider default; providers whose plans fix the disk reject a value. | `number` | `null` | no |
| jumphost\_image | OS image (AMI, image name or OS ID) of the jumphost. Null uses the provider default (an openSUSE Leap image). | `string` | `null` | no |
| jumphost\_instance\_type | Machine type, flavor or plan of the jumphost that builds the image and serves as SSH bastion. Null uses the provider default. | `string` | `null` | no |
| jumphost\_username | Login user of the jumphost. Empty makes the jumphost root-only. | `string` | `"suse"` | no |
| keep\_build\_artifacts | Keep the intermediate build artifacts (raw image, build disks) after the image is registered. No effect on vultr, which builds on the jumphost. | `bool` | `false` | no |
| lb\_backend\_instance\_ids | Instance IDs attached to the load balancers as backends. Empty on pass 1 and filled from control\_plane\_ids on pass 2, because a reference would close a dependency cycle with the image build. | `list(string)` | `[]` | no |
| lb\_supervisor\_extra\_cidrs | Extra CIDRs allowed to reach the load balancer on 9345, typically the public /32s of agent nodes. deploy.sh fills it from the agent\_node\_cidrs value on pass 2. | `list(string)` | `[]` | no |
| mdisk\_mode | Managed disk mode of bare metal agent nodes (raid1, jbod or none). Applies to gpu\_pools and worker\_pools entries with kind = "bare\_metal" only. | `string` | `"none"` | no |
| node\_user\_password\_hash | Crypt hash for node\_username. | `string` | n/a | yes |
| node\_username | Unprivileged login account created on every node. | `string` | `"suse"` | no |
| nvidia\_api\_key | NVIDIA NGC API key. Optional, recommended with aif-operator; unset omits the nvidia credentials block. | `string` | `null` | no |
| nvidia\_username | NGC username paired with nvidia\_api\_key; NGC uses the literal $oauthtoken for API-key auth. | `string` | `"$oauthtoken"` | no |
| permit\_root\_ssh | Allow SSH logins as root and install ssh\_authorized\_keys for it. Debug toggle. | `bool` | `false` | no |
| rancher\_bootstrap\_password | Rancher initial admin password; a random one is generated when null. | `string` | `null` | no |
| rancher\_hostname | Hostname of the Rancher ingress. Null selects a provider-specific default. | `string` | `null` | no |
| region | Provider region or location. Required by providers that have no region default; the provider module checks it. | `string` | `null` | no |
| root\_password\_hash | Crypt hash for the root account (for example from `openssl passwd -6`). | `string` | n/a | yes |
| ssh\_authorized\_keys | SSH public keys for node\_username, and for root when permit\_root\_ssh is set. | `list(string)` | n/a | yes |
| ssh\_key\_ids | Vultr SSH key IDs injected into the jumphost and every node that has a public NIC. | `list(string)` | `[]` | no |
| suse\_registry\_password | SUSE registry password, paired with suse\_registry\_username. | `string` | `null` | no |
| suse\_registry\_username | SUSE registry username. Optional, set together with suse\_registry\_password; recommended with aif-operator. | `string` | `null` | no |
| suse\_storage\_nodes | Where the suse-storage (Longhorn) disks live: roles (control\_plane, worker for all worker\_pools, gpu for all gpu\_pools) and/or pool names, e.g. ["control\_plane", "storage"]. At least three such nodes are required. | `list(string)` | <pre>[<br/>  "control_plane"<br/>]</pre> | no |
| sysext\_image\_overrides | Beta workaround: per-extension OCI image overrides written into the release manifest, keyed by extension name. See docs/workarounds.md. | `map(string)` | <pre>{<br/>  "suse-storage": "registry.suse.com/beta/uc/longhorn:5.279-4.13"<br/>}</pre> | no |
| tags | Extra tags or labels on every resource that supports them. Keys must not use the elemental- prefix, which the module manages. | `map(string)` | `{}` | no |
| vpc\_cidr | IPv4 CIDR of the cluster network, from which subnets are derived; null uses the provider default. Must not overlap the RKE2 cluster (10.42.0.0/16) or service (10.43.0.0/16) CIDRs. | `string` | `null` | no |
| vpc\_mtu | MTU of the cluster network interfaces; the pod MTU is derived from it. Null uses the provider default. | `number` | `null` | no |
| vultr\_api\_key | Vultr API key for the plan-time stock checks, load balancer address lookups and the wait scripts. The root module also passes it to the vultr provider. | `string` | n/a | yes |
| worker\_pools | Worker pools without GPUs keyed by pool name, with the same fields as gpu\_pools. Hostnames are <cluster\_name>-<pool>-NN, so keys must not collide with gpu\_pools keys. | <pre>map(object({<br/>    instance_type = string<br/>    count         = optional(number, 1)<br/>    disk_size_gb  = optional(number)<br/>    zone          = optional(string)<br/>    public_ip     = optional(bool, false)<br/>    kind          = optional(string, "vm")<br/>    placement     = optional(string)<br/>  }))</pre> | `{}` | no |
| zones | Zone suffixes the cluster spans (for example ["a", "b", "c"]); control planes are spread round-robin. Empty uses the provider default; providers without zones accept at most one entry. | `list(string)` | `[]` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| api\_host | DNS name of the Kubernetes API; it is in the API server certificate SANs. |
| api\_vip | IPv4 of the API load balancer. |
| build\_status | Image import URL and the build hosts reachable via the jumphost while no snapshot exists yet; null once it does. |
| cluster\_name | Cluster name. |
| egress\_ips | Public source IPs of cluster egress (NAT gateway). |
| image | Image build ID and the snapshot ID per region. The snapshot is account-wide: one key, none while it does not exist. |
| ingress\_endpoint | URL of the ingress load balancer. null unless ingress\_controller is traefik. |
| jumphost | Jumphost addresses and login user (root when jumphost\_username is empty). |
| kubernetes\_api\_endpoint | Kubernetes API URL on api\_host, port 6443. |
| network | VPC CIDR and subnet CIDRs. |
| next\_steps | Post-deploy hints. |
| nodes | Cluster nodes keyed by hostname. Empty when deploy\_nodes is false. |
| provider | Provider name, for tools that dispatch on it. |
| provider\_details | Vultr-specific values. agent\_node\_cidrs and agent\_cloud\_firewall\_group\_id cover GPU and worker agents alike; node\_tags lists the tags of each node (build\_id makes vultr\_instance tags unknown at plan). |
| rancher\_bootstrap\_password | Rancher initial admin password. null when rancher is not in components. |
| rancher\_hostname | Hostname Rancher's ingress is configured for. null when rancher is not in components. |
| rancher\_url | Rancher UI URL. null when rancher is not in components. |
| region | Vultr region the cluster runs in. |
<!-- END_TF_DOCS -->

## Known gaps

- **Bare metal nodes have no platform firewall.** Vultr offers none for bare
  metal; use `kind = "vm"` pools where stock allows. See
  [`docs/providers/vultr.md`](../../docs/providers/vultr.md#security).
- **`elemental_image` defaults to a beta build.** It carries `apiVIPMode`
  support and can be superseded; move to a tagged release once one ships it.
- **UEFI of the imported snapshot cannot be read back.** `use_uefi` is write-only
  in the API; the check is a node that boots.
- **The snapshot import runs once.** A failed fetch means recovery with
  `terraform state rm` and a re-run; see the example README's troubleshooting.
- **The jumphost serves for a fixed window** (`image_serve_seconds`, 3600), not
  until the import ends, because it has no API key to check.
- **`kind = "vm"` pools have run on one plan only** (`vcg-a40-24c-120g-48vram`,
  see [`docs/providers/vultr.md`](../../docs/providers/vultr.md#cloud-gpu)).
  Whole-node plans are often out of stock; bare metal pools are the most
  exercised path.
- **Longhorn persistence across a reboot is unproven.**
- **`appco_registry` assumes the container registry host equals the Helm
  repository host** (`dp.apps.rancher.io`); override it if a pod cannot pull.

## Non-goals

- Cross-region GPU pools (VPCs and load balancers are regional).
- A preemptible flag (no API surface).
- Per-pool `region`, `vpc_subnet`, `tags`, `ssh_key_ids` or `enable_ipv6`.
- Day-2 operations such as upgrades or removing the jumphost after the build.
