# evroc platform notes

Platform behaviour of [evroc](https://www.evroc.com/) that the module design
follows from, and the choice each one led to. Read it before changing how the
image reaches the nodes, before sizing GPU pools, and before assuming a boot
failure is the image's fault. The module is [`modules/evroc`](../../modules/evroc/),
the runnable root is [`examples/evroc`](../../examples/evroc/README.md).

An [elemental3](https://github.com/suse/elemental) image is EFI-only and
immutable: no writable root, no post-boot compilation. Most sections below are
what happens when those two properties meet evroc.

Provider: [`evroc-oss/evroc`](https://registry.terraform.io/providers/evroc-oss/evroc),
`~> 0.9.4`. Attribute names are from that schema. Workarounds tied to upstream
defects (load-balancer 409 retry, beta OS image, GPU driver
override) are listed in [workarounds.md](../workarounds.md) and not repeated here.

## Passes

Diagrams: [architecture](../architecture.md#evroc-two-passes-plus-an-optional-third).

`examples/evroc/deploy.sh` runs up to three applies.

| Pass | Name in `deploy.sh` | What it does |
|---|---|---|
| 1 | Build image (`image_ready=false`) | Network, API VIP, load balancer, one build host per zone, one blank disk per zone attached to its build host. Each host builds the raw image and writes it to the disk. |
| 2 | Create nodes (`image_ready=true`, `keep_build_artifacts=true`) | Destroys the attachments (the detach), destroys the non-primary build hosts, snapshots each freed disk, clones every node boot disk from its own zone's snapshot. |
| 3 | Reclaim build disks (`image_ready=true`) | Deletes the image-target disks. No changes when `keep_build_artifacts = true` is set in `terraform.tfvars`. |

Why more than one pass:

- The platform has no import-image-from-URL. `evroc_snapshot` takes only a
  `disk_ref`, so the image has to be written to a disk inside the project. A
  disk cannot be attached and detached in one apply, and the snapshot is taken
  from the detached disk. That is passes 1 and 2, sequenced by `image_ready`.
- Creating a snapshot and deleting its source disk in one apply depends on an
  ordering Terraform does not pin down. Reclaiming the disks is therefore its
  own apply (pass 3). A snapshot stays usable after its source disk is deleted;
  booting a node from such a clone is the untested step, so
  `keep_build_artifacts = true` keeps the disks.
- Snapshots are zonal (see below), so passes 1 and 2 cover every zone.

Once a snapshot is in state, `deploy.sh` runs a single apply with
`image_ready=true`, because going back through pass 1 destroys the snapshots.
`deploy.sh --rebuild` bumps the rebuild counter
([ADR 003](../decisions/003-rebuild-counter.md)) and always runs pass 1 again.
After pass 2 it writes `pass2.auto.tfvars.json` so a later bare
`terraform apply` keeps `image_ready = true`.

Build hosts never hold evroc credentials: Terraform owns the detach and the
snapshot. The image-target disks are written in full (`dd` without
`conv=sparse`), since the disk is reused across rebuilds and a zero region in
the new image must overwrite the old bytes.

## UEFI is an experimental, label-gated feature

VMs boot BIOS by default. UEFI is selected per VM with the label
`compute-experimental-features-UEFI = "true"`; there is no boot-mode field on
`evroc_virtual_machine`. The module sets the label on every node VM.

Elemental installs GRUB into the EFI system partition and no BIOS boot sector,
so a BIOS-booting VM has no bootloader. The API reports it `Running` and it
never answers on any port. The label prefix marks the interface as
experimental: if a boot suddenly stops working, check the label first.

## There is no console

Neither the CLI nor the web UI offers a serial console or VNC. Every failure
in the boot path looks the same from outside: the VM is `Running` and `Ready`
within seconds and nothing answers. `Ready` means the hypervisor runs the VM,
not that userspace started. Failures that present this way:

- no bootloader (missing UEFI label),
- GRUB loads but no kernel starts,
- kernel panic, or root not found,
- Ignition fails and drops to a dracut emergency shell,
- the system boots and only `sshd` is missing.

Two aids exist. evroc support can retrieve console logs through a ticket. A
disk can also be read directly: hotswap it onto the jumphost and read the ESP
and root filesystem. The image-target disks hold the bytes the snapshots were
taken from; set `keep_build_artifacts = true` to keep them.

```bash
evroc compute hotswapdiskattachment create forensics-a \
  --disk-ref <cluster>-image-target-a --vm-ref <cluster>-jumphost
# on the jumphost: parted -s /dev/sda print; mount /dev/sda1 /mnt
evroc compute hotswapdiskattachment delete forensics-a   # before any later apply
```

Build progress has the same constraint: nothing can be read from a console, so
each build host `PUT`s a status line to a small relay on the jumphost
(`templates/status-relay.py`, port 8080) and `terraform_data.image_written`
polls it over HTTP (`modules/evroc/scripts/wait-for-image.sh`). A `failed` report ends pass 1
at once. `scripts/build-logs.sh` follows `/var/log/elemental-factory.log` on the
hosts listed in the `build_status` output; during the apply, while the outputs
are not in the state file yet, it reads `terraform_data.build_access` from state
(it exists once every build host does; remote backends:
[conventions](../conventions.md#following-a-build)). The relay accepts writes from
`vpc_cidr` only and reads from `admin_cidrs`; pass 2 removes its security-group
rules. The relay is one of the two accepted instance-side Python uses.

The build script does not record boot diagnostics. To inspect an image that
does not boot, read a kept image-target disk on a build host before pass 2.

## Snapshots are zonal

`evroc_snapshot` has a `region` attribute and no `zone`; it takes the zone of
its source disk. Plan and apply succeed, and the constraint appears when a node
disk in another zone clones it:

```
admission webhook "disk-webhook.evroc.com" denied the request: snapshot
"<name>" is in zone "a" but disk is in zone "c"
```

There is no snapshot-copy resource and no cross-zone disk clone. The module
builds the image once per zone (one build host, one image-target disk, one
snapshot each) and every node clones its own zone's snapshot. Three zones are
three concurrent builds; they run in parallel, so the cost is compute rather
than wall-clock time. `image_ids` (a map by zone, an entry for every zone in
use) adopts existing snapshots instead of building.

Consequences:

- Only `zones[0]`'s build host (`evroc_virtual_machine.jumphost`) has a public
  IP. The other zones' hosts (`evroc_virtual_machine.builder`) are private,
  reached with `ProxyJump` through the jumphost, in a security group that admits
  SSH from the jumphost's private address only. Two resources rather than one
  `for_each`, because the builders' group reads the jumphost and Terraform
  tracks dependencies per resource.
- The zones' images are not compared. OCI tags can move mid-build, and an
  elemental raw image is not reproducible (filesystem UUIDs, GPT GUIDs and
  mtimes differ per run), so results cannot be diffed. Pin digests instead of
  tags in `elemental_image`, `core_platform_override` and `sysext_image_overrides`.
- Build hosts are destroyed in pass 2, before any node exists, because the
  default 20 vCPU quota does not hold both. `evroc_snapshot.ai_factory` depends
  on that teardown. If pass 2 fails partway, recover with `deploy.sh --rebuild`.
- `zones = ["a"]` is the single-zone shape: one build host, one snapshot.
  Zones are position-numbered (`cidrsubnet(vpc_cidr, 4, i)`): do not reorder
  the list on a standing cluster.

Resources split into regional (`evroc_vpc`, `evroc_loadbalancer`,
`evroc_lb_backend_pool`, `evroc_public_ip`, `evroc_security_group`) and zonal
(`evroc_subnet`, `evroc_placement_group`, `evroc_disk`,
`evroc_virtual_machine`, `evroc_snapshot`). A VM attaches only to a subnet in
its own zone, so there is one subnet per zone and one load balancer for all.

A placement group is zonal too, so the module creates one `spread` group per
zone for the control planes. Worker and GPU pools opt in per pool with
`placement = "spread"` or `"cluster"`; each gets one group in the pool's zone
(`zones[0]` when unpinned).

## Disk provisioning

The provider waits 10 minutes for a disk to become Ready, then fails the apply
and marks the disk tainted, which forces a destroy and re-create on the next
apply. Provisioning time varies by zone. The module sets
`timeouts { create = "30m", delete = "20m" }` on every disk
(`local.disk_create_timeout`, `local.disk_delete_timeout`).

Some image-backed disk imports in a zone can stay in
`Ready=False, reason: ImportScheduled` indefinitely (`lastTransitionTime` equal
to `creationTimestamp`). Nothing in Terraform recovers from it. Limit `zones`
to the zones that provision, for example `zones = ["a", "b"]`; this replaces
the load balancer (`backend_network` forces replacement, the VIP survives).

## Locating the attached disk in the guest

Hotswap disks are SCSI (`/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_<serial>`).
The serial is platform-assigned and exists only after the attachment, which
needs the jumphost, whose user data is the build script. The script therefore
identifies the disk by bus: the boot disk (`vda`) and the config drive (`vdb`)
are virtio and have no `by-id` entry, so exactly one `scsi-0QEMU_QEMU_HARDDISK_*`
match is the target. Zero matches waits (up to 20 x 15 s); more than one is
refused. After the `dd`, the script checks for a GPT signature at offset 512.

## GPUs

GPU flavors are ordinary `evroc_virtual_machine` profiles in the same namespace
(`gn-l40s.{s,m,l}`, `gn-b200.{s,m,l,xl}`). They sit behind an
`evroc_security_group` like every other node; the module's network policy does
not rely on a host firewall in the image.

- **Passthrough.** `gn-l40s` presents the whole card (`nvidia-smi` reports
  46068 MiB). The GPU operator on an immutable OS needs precompiled driver
  containers, which do not support vGPU, so passthrough is required.
- **Snapshot boot.** GPU VMs boot from this module's snapshot clones, like the
  control plane. Projects that still enforce the older rule (GPU flavors only
  from disks with a `diskImageRef`) fail with
  `Ready: disk is missing DiskImageRef (ProvisioningFailed)`.
- **Zone.** An admission webhook admits GPU VMs in zone `a` only
  (`cannot deploy a GPU VM in zone "b"`). It fires per VM at apply time, after
  the boot disk exists, so the module checks it at plan time with
  `local.gpu_zones = ["a"]`. An unpinned pool uses `zones[0]`; a pool pinned to
  another zone fails the plan. The node's zone is also the zone of the snapshot
  it clones, so zone `a` must be in `zones`.
- **Quota is per GPU model and counted in GPUs.** The flavor size is the GPU
  count and the webhook compares `count x gpu_quantity`. An unmodified project
  holds one L40S, so `gn-l40s.s` with `count = 1` is the only pool it can apply.
  GPU vCPUs are not drawn from the compute quota.

  | flavor | GPUs | vCPUs | memory |
  |---|---|---|---|
  | `gn-l40s.s` / `.m` / `.l` | 1 / 2 / 4 | 15 / 30 / 60 | 190 / 380 / 760 GB |
  | `gn-b200.s` / `.m` / `.l` / `.xl` | 1 / 2 / 4 / 8 | 26 / 52 / 104 / 208 | 260 / 520 / 1040 / 2080 GB |

  No data source exposes the GPU quota, so it cannot be checked at plan time.
  The demand is known: `provider_details.gpu_quota_request` (`by_pool`,
  `by_model`) shows what the webhook will compare. A denied create leaves the
  node's boot disk behind; it stays in state and is removed by lowering
  `count` or by `terraform destroy`.
- **Driver.** The manifest's precompiled driver
  (`registry.suse.com/third-party/nvidia`) is published for SLES 16.0 and does
  not load on the 16.1 kernel (`disagrees about version of symbol
  module_layout`). The module defaults `gpu_driver_repository` and
  `gpu_driver_version` to an experimental OBS 16.1 build (see
  [workarounds.md](../workarounds.md)). The operator pulls
  `<repository>/driver:<version>-<uname -r>-sles16.1`, so the repository needs a
  tag for the node's exact kernel.

`gpu_pools` defaults to `{}`: a GPU pool is opt-in, quota-limited and costly.

## Worker pools

`worker_pools` (same schema as `gpu_pools`) adds non-GPU agent nodes, for
example for Longhorn storage or general workloads. Both kinds share one code
path, hostnames (`<cluster_name>-<pool>-NN`), the per-zone snapshot clone, the
security group and the optional placement groups; only the role differs
(`worker` or `gpu` in `nodes` and in the `elemental-role` label; the shared security group is `agent`).
Workers are not restricted to GPU zones: a pool may use any zone in `zones`,
and an unpinned pool uses `zones[0]`. A flavor with GPUs is rejected in
`worker_pools` at plan time. Pool keys must differ from `gpu_pools` keys.

## Load balancer

One `evroc_loadbalancer` serves four listeners; health check and PROXY protocol
are properties of the backend service:

```
:6443 -> route -> backend_service(tcp health check)
:9345 -> route -> backend_service(tcp health check)
:80   -> route -> backend_service(proxy_protocol, http /ping on 8080)
:443  -> route -> backend_service(proxy_protocol, http /ping on 8080)
                  all four -> one backend pool (control-plane fqids)
```

The diagram shows `ingress_controller = "traefik"`. The 80/443 health check
targets 8080 because Traefik's 80/443 entrypoints expect a PROXY header the
health checker does not send; `hostPort: 8080` on the Traefik pod is an
unwrapped `/ping`. PROXY protocol must be on in the backend service and in
Traefik together. With `ingress-nginx` the services use no PROXY protocol and a
TCP check on 80/443; with `none` the 80/443 services, routes and listeners are
not created.

- **`backend_network`.** A load balancer without it attaches to the default
  VPC and cannot reach backends in a custom VPC. Every connection to the VIP is
  accepted and reset while all objects report `Ready`. Provider 0.9.4 added
  the block (`versions.tf` requires it), and it forces replacement, so changing
  `vpc_cidr` or `zones` recreates the load balancer.
- **Health-check `target_port`.** If omitted, the API stores 0 and the check
  never passes: the listener accepts and resets. `loadbalancer.tf` always sets
  it (`coalesce(health_check_target, port)`).
- **Restated defaults.** The provider declares several backend-service
  attributes Optional without Computed (`ip_protocol_selection`, the health
  check `interval`, `timeout`, thresholds, `http.expected_statuses`), so each
  plan proposes unsetting the API default. The module pins them to the API
  values so plans are empty.
- **Concurrent updates.** Changing more than one load-balancer object in one
  apply can return `API error (409)` (optimistic-concurrency conflict on the
  reconciled objects). `deploy.sh` retries a pass up to three times, only on
  that error; see [workarounds.md](../workarounds.md).
- **No per-backend health.** Objects report `Ready` when reconciled, and
  `status.backends` lists membership, not health. Check reachability with
  `curl`.

## API VIP

`evroc_public_ip` is a standalone resource, so the VIP is known before the
load balancer, the jumphost or the image exist. The image bakes `cluster.yaml`
with the VIP, so allocation, build and attachment have no dependency cycle,
and the cluster uses `apiVIPMode: external` (no MetalLB or kube-vip). RKE2
servers retry the 9345 registration until it answers, so the backend pool can
fill after the VMs exist.

## Jumphost

`data.evroc_disk_images.this.opensuse_15_6_1` (openSUSE Leap 15.6, python 3.6):
the build host image, since `elemental customize` runs in podman and the host
only needs podman, python3 and curl. The `jumphost_username` account (default
`suse`) has passwordless sudo from cloud-init, which lets the build script run
privileged and `dd` to a block device. The jumphost holds the rendered
elemental config with every credential and is the only inbound admin path;
`admin_cidrs` is the only filter in front of it. Nodes have no sudo.

Size it for the work: it holds the pulled OCI layers, the raw image and a
working copy. `jumphost_disk_size_gb` defaults to 200.

## Networking

- **Addressing.** `vpc_cidr` must not overlap RKE2's `10.42.0.0/16` or
  `10.43.0.0/16`; the module validates it. An overlap shows up as intermittent
  host-specific connectivity loss.
- **MTU is 8900.** DHCP hands out 8900; there is no `network-config` on the
  config drive. `vpc_mtu` defaults to 8900 and the pod MTU is `vpc_mtu - 50`.
  `configure-network.sh` sets the NIC to `vpc_mtu`, so a 1500 in tfvars lowers
  a link the platform brought up at 8900. The variable is range-checked
  (1330-9000). A wrong value fails silently: small packets pass, large ones
  vanish, TLS handshakes hang. Confirm with `ping -M do -s 8872` between two
  VMs.
- **One NIC.** Each VM has one interface with the private address; the public
  IP is 1:1 NAT and does not appear in the guest. `configure-network.sh` and
  `write-node-ip.sh` detect a single NIC and do nothing, and RKE2's default
  `node-ip` is correct. The image disables IPv6 per interface at boot.
- **Egress without a public IP.** Outbound traffic goes through shared NAT
  gateways that are not user-configurable. Rancher, the AppCo charts and the
  GPU operator's driver images are pulled at runtime through them, and
  `control_plane_public_ip` and worker- and GPU-pool `public_ip` default to `false`.
  Nodes without a public IP present a platform-owned source address, so
  upstream allowlists cannot use it (`egress_ips` lists only nodes that have
  one). Egress is governed by security groups: default deny, opened by
  `egress_all_rules` (all TCP and UDP to `0.0.0.0/0`). ICMP is blocked in both
  directions, so `ping` between VMs fails; probe a TCP port. If nodes are
  `Ready` and chart installs sit in `ImagePullBackOff`, check egress first
  (`curl -sSf https://dp.apps.rancher.io/v2/` from a node).
- **IPv4-only VMs are refused** (`IPv4OnlyStackTypeDeprecated`). Provider 0.9.5
  rejects `ipv4-only` at plan time. The module leaves `stack_type` unset
  (inherits the subnet's `dual-stack`).
- **Public IPs are recycled across clusters.** A new jumphost can get an
  address a destroyed one had, with a different host key. `scripts/ssh.sh` uses
  a throwaway `known_hosts`, so it is unaffected; a manual `ssh` may need
  `ssh-keygen -R <ip>`.

## Quota

Quota is enforced by admission webhooks at create time. The defaults of an
untouched project (raisable on request to evroc) are 20 vCPU, 160 GB memory
and 3 public IPs, plus a per-model GPU quota.
`data.evroc_organization_quota` exposes vCPU, memory and public IPs with usage;
`data.evroc_project_quota` covers object storage only.

The module fails at `terraform plan` (hard failure, not a warning) when:

- the cluster's footprint exceeds the organization limit
  (preconditions on `evroc_vpc.this`). The footprint is the maximum over passes
  of what exists at once: pass 1 is the jumphost plus one builder per other zone on
  `jumphost_instance_type`; pass 2 is the jumphost plus the control planes plus the `worker_pools` nodes
  (ordinary compute, so their vCPU and memory count; GPU nodes' do not).
  Public IPs are the API VIP, the jumphost and the optional per-node IPs of
  control planes, workers and GPU nodes.
  Usage by other workloads is not checked, and the result does not depend on
  the pass, a re-apply or `--rebuild`;
- a requested flavor is not offered (`data.evroc_compute_profiles`).

On `--rebuild`, pass 1 destroys the nodes and creates the builders in the same
apply, in no fixed order. An organization at its limit can reject a builder at
apply time; re-run `deploy.sh` to finish.

All need API reachability at plan time. `provider_details.quota_request` shows
the footprint, limit and usage.

Public IPs: the API VIP and the jumphost use two of the default three, so
`control_plane_public_ip = true` does not fit on a default project. It also
does not scale with zones: only `zones[0]`'s build host has one.

vCPU is the binding limit. `jumphost_instance_type` defaults to `a1a.m` (4 vCPU)
because three `a1a.l` build hosts (24 vCPU) exceed 20:

| | vCPU |
|---|---|
| pass 1: 3 build hosts, `a1a.m` | 12 |
| pass 2: jumphost + 3 control planes, `c1a.m` | 16 |
| default quota | 20 |

Quota release is asynchronous: a control-plane create right after the builders
are destroyed, or a deploy right after another cluster's destroy, can be denied
for a short time on capacity the console shows as free. Re-run `deploy.sh`.

## Node configuration

Every node boots the same image. Its role comes from per-node Ignition in
`cloud_config_user_data`, which writes `/etc/hostname` and
`/var/lib/elemental/runtime.env` (`NODETYPE=server|agent`, and
`IS_INIT_NODE=true` on the first control plane only). `cluster.yaml` has no
`nodes:` list, so adding a GPU pool is a plain add, not an image rebuild.

- **User data** is a NoCloud drive (`vdb`, 1 MB, label `cidata`, files
  `user-data` and `meta-data`), delivered byte for byte, with no
  `network-config`. The platform limit is 1 MB on the VM object. Node user data
  is checked against 768 KiB; build-host user data against 32 KiB, a size
  tripwire for template bugs that render content twice.
- **`ignition.platform.id=proxmoxve`.** The id selects a config-delivery
  convention, not a hypervisor. The guest reports KubeVirt, but the
  `kubevirt` provider reads a ConfigDrive (`config-2`) and retries without
  bound on the NoCloud drive evroc presents, so Ignition never finishes and
  the VM shows `Running` with nothing listening. `proxmoxve` reads NoCloud
  `cidata`. Node user data therefore cannot start with `#cloud-config`.
  A wait on `/dev/disk/by-label/ignition` in the console log is harmless.
- **The built image is installation media.** It has an `EFI` and a `RECOVERY`
  partition and a GRUB entry titled `... (Installer)`. `SYSTEM` is created on
  the first boot, which ends in a normal reboot; the second boot is the
  installed system. The module's kernel command line applies from the second
  boot.
- **OS image and `elemental3ctl`.** The install is run by the `elemental3ctl`
  inside the OS image. GA 3.0.x ignores `bootloader.initrdExtensions`, so a node
  installs, reboots and has no Kubernetes, users or sshd
  (`no config dir at "/usr/lib/ignition/base.d"` in the journal). The module
  pins a beta 16.1 OS image through `core_platform_override`; see
  [workarounds.md](../workarounds.md). An installer GRUB title of
  `SUSE Linux Enterprise Server 16.0` means the GA image booted.

## Security

Every sensitive input is stored in Terraform state in plaintext and baked into
the image, so state and the snapshots are credentials. Restrict read access to
both. See [security.md](../security.md).

| Group | Inbound |
|---|---|
| jumphost | 22 from `admin_cidrs`; status relay from `admin_cidrs` (pass 1 only) and `vpc_cidr` |
| builder (multi-zone) | 22 from the jumphost private address |
| control plane | 22 from `admin_cidrs` and the jumphost; 6443 from `api_cidrs` and the VPC; 9345 from `0.0.0.0/0`; etcd, kubelet, VXLAN and NodePorts from the VPC; 80, 443 from `ingress_cidrs` and, with Traefik, 8080 (`/ping` health check) from `0.0.0.0/0` |
| agent (worker and GPU nodes) | 22 from `admin_cidrs` and the jumphost; kubelet, VXLAN and NodePorts from the VPC |

Egress is unrestricted, since the image pulls charts and driver images at
runtime. The load balancer keeps the client address, so these rules filter its
listeners. 9345 is open because nodes without a public IP join from undisclosed
egress addresses; it requires TLS and the join token. The health checker's
source is not disclosed either: with `api_cidrs` narrowed, the 6443 check
targets 9345.

## Cost estimate

`make cost PROVIDER=evroc TFVARS=...` estimates the cost from tfvars
([tools/cost](../../tools/cost/README.md)). evroc provides no pricing API, so
rates come from the checked-in `ratecard.json` (public calculator, EUR,
excluding VAT, dated by `as_of`; refresh with
`tools/cost/scripts/refresh-evroc-ratecard.sh`). It prices VMs, SSD disks and
reserved public IPs; builder VMs and build disks are listed as build only. The
load balancer and snapshot rates are not published and outbound transfer is
traffic-dependent, so none of them is included. The result is an estimate, not
a quote.

## Leftover check

```bash
tools/leftovers/evroc.sh <cluster_name> [--region <region>] [--project <project>]
```

Read-only. Uses the `evroc` CLI because it handles every login method and token refresh. Credentials
are the usual ones (`evroc login`, `EVROC_CONFIG_FILE` via `--config`, or the `EVROC_*` variables),
never the tfvars. Project and region come from the login; `--region` and `--project` override them by
setting `EVROC_REGION` and `EVROC_PROJECT` (the SDK variables) in the CLI's environment. The report
header shows the project and region queried. `deploy.sh` passes the `project` and `region` variables
when set. Lists VMs, disks, snapshots, placement groups, public IPs, security groups, subnet, VPC and
the load-balancer objects labelled `elemental-cluster=<cluster_name>` (collections are regional, so
one call per type covers every zone). `deploy.sh --destroy` prints the command at the end; it never runs it. Exit 0 means
nothing is left, 1 something is, 3 the check was inconclusive. Hotswap attachments carry no labels and
are not listed.

A response with items that lack `.metadata.userLabels["elemental-cluster"]` makes the tool exit 3
instead of dropping them.

## Sources

- [`evroc-oss/terraform-provider-evroc`](https://github.com/evroc-oss/terraform-provider-evroc)
- NVIDIA, [Precompiled Driver Containers](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/precompiled-drivers.html)
- SUSE, [GPU operators on RKE2](https://documentation.suse.com/cloudnative/rke2/latest/en/add-ons/gpu_operators.html)
- SUSE, [`third-party/nvidia/driver` images](https://registry.suse.com/repositories/third-party-nvidia-driver-sles16)
