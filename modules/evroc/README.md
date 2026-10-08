# `modules/evroc`

Stands up a SUSE AI Factory cluster on evroc: RKE2 in HA behind a single L4
load balancer, Rancher, the AI Factory operator and optional worker and
GPU pools, every node booted from a self-built [elemental3](https://github.com/suse/elemental)
image with the OS, Kubernetes and the chart set baked in at build time.

For the platform facts this design is built around -- the experimental UEFI
label, the absence of import-image-from-URL, what is still unverified -- read
[`../../docs/providers/evroc.md`](../../docs/providers/evroc.md). For a working invocation,
see [`../../examples/evroc`](../../examples/evroc).

## Design

### The two passes

evroc has no import-image-from-URL, so the image is built on a jumphost inside
the project and handed over as a snapshot. That handoff cannot happen in one
apply, because Terraform will not attach and detach the same disk within a
single graph walk:

| | `image_ready` | What happens |
|---|---|---|
| Pass 1 | `false` | VPC, subnets, API VIP, security groups and the load balancer come up. One blank `evroc_disk.image_target` per zone is attached to that zone's build host by `evroc_hotswap_disk_attachment`. `image-factory.sh` builds the raw elemental image on each and `dd`s it onto the attached disk. Each build host publishes its progress to a status relay on the jumphost (`templates/status-relay.py`, port 8080), and `terraform_data.image_written` blocks on `modules/evroc/scripts/wait-for-image.sh`, which polls that relay over plain HTTP until every zone reports `done` for this build's id -- or stops at once if one reports `failed`. |
| Pass 2 | `true` | The attachments drop to an empty `for_each`, which **is** the detach. One `evroc_snapshot.ai_factory` per zone is taken from the now-free disks. Each node's boot disk is an `evroc_disk` cloned from its own zone's snapshot, and the control planes populate the load balancer's backend pool. |

This module requires **provider 0.9.4 or a later 0.9.x** (`versions.tf` enforces it):
it is the first release where `evroc_loadbalancer` accepts `backend_network`,
without which the load balancer lands in the default VPC, cannot reach its own
backend pool, and resets every connection at the VIP while reporting `Ready`.
Note that `backend_network` forces replacement, so changing `var.vpc_cidr` or
`var.zones` rebuilds the load balancer.

A third apply reclaims the image-target disks (`keep_build_artifacts = false`,
the default). It has to be a separate apply: creating a snapshot and destroying
its source in the same one races. `deploy.sh` runs pass 2 with
`keep_build_artifacts=true` and pass 3 with the value from `terraform.tfvars`,
so `keep_build_artifacts = true` there keeps the disks. A snapshot survives its
source disk, but no node has yet been booted from a clone made after that disk
was deleted.

`examples/evroc/deploy.sh` drives every pass and pins `image_ready` in an
auto-loaded `pass2.auto.tfvars.json` so a later bare `terraform apply` does not
revert it. Once the snapshot is in state, a bare apply is safe and the script
does a single pass. `--rebuild` bumps `image_rebuild` (persisted in
`rebuild.auto.tfvars.json`, [ADR 003](../../docs/decisions/003-rebuild-counter.md))
and always runs pass 1 again.

The API VIP is a standalone `evroc_public_ip`, so its address is known before
the load balancer, the jumphost or the image exist. That is what lets the image
be built against a live `apiVIP` with no dependency cycle.

### `var.image_ids` is not a pin

It means *"do not build an image, adopt these externally-owned snapshots"*, and
`evroc_snapshot.ai_factory` is gated on it being **empty**. Setting it to the
FQIDs of the snapshots this module built destroys those resources while every
node disk still refers to the ids. There is no need to pin: once created, a
snapshot's FQID is in state and already plan-known.

It is a map keyed by zone, with an entry required for every zone in
`var.zones`, because evroc snapshots are zonal -- there is no single id that
serves a multi-zone cluster.

### Node roles

`kubernetes/cluster.yaml` carries **no `nodes:` list**. Each node's role is
declared once, by per-node Ignition in `cloud_config_user_data`, which writes
`/etc/hostname` and `/var/lib/elemental/runtime.env` with
`NODETYPE=server|agent` plus `IS_INIT_NODE=true` on `cp-01` only (omitted, not
`false`, elsewhere). Adding a worker or GPU pool is therefore an add, not an image
rebuild and cluster replacement.

The per-node Ignition (`module.config.node_runtime_ignition`) is built in
`modules/elemental-config/ignition.tf` as JSON, not through butane. File
contents are `data:;base64,` URIs, because percent-encoding renders a space as
`+`, which a `data:` URI does not decode. The same file also writes the
Longhorn disk label for `suse_storage_nodes` and, on servers, `canal.yaml`.

### Where nodes land: zones and placement groups

evroc's resources split into regional and zonal, and that split decides what a
multi-AZ cluster costs:

| Regional (one, shared) | Zonal (one per zone) |
|---|---|
| `evroc_vpc` | `evroc_subnet` |
| `evroc_loadbalancer`, `evroc_lb_backend_pool` | `evroc_placement_group` |
| `evroc_public_ip`, `evroc_security_group` | `evroc_disk`, `evroc_virtual_machine` |
| | `evroc_snapshot` -- see below |

So one load balancer fronts backends in every zone. Everything else a node is
made of is per-zone, **including the image it boots**.

Control-plane nodes are assigned round-robin across `var.zones` **by node
index** -- `cp-01` to `zones[0]`, `cp-02` to `zones[1]`, wrapping. Index-based
rather than anything that balances the final layout, because the assignment has
to be a pure function of the node's own number: a scheme that filled the
emptiest zone would move existing members between zones as
`control_plane_count` changed, and moving an etcd member means destroying and
recreating it.

The two failure domains stack rather than substitute. A zone is what evroc
loses as a whole; a placement group with `strategy = "spread"` only constrains
placement **within** one zone, so there is one per zone. On the default
three-nodes-over-three-zones layout each group holds one VM and does nothing --
it earns its keep the moment `control_plane_count` exceeds the zone count and
two members share a zone.

GPU pools boot the same snapshot clone as everything else. A project that
still enforces the older GPU boot-disk rule fails with `disk is missing
DiskImageRef`; see [docs/providers/evroc.md](../../docs/providers/evroc.md#gpus).

evroc runs GPU VMs in **zone `a` only**, so an unpinned pool defaults to
`zones[0]`, which the module checks is a GPU zone. The admission webhook fires
per VM during apply, after that node's boot disk exists, which is why the
module checks the zone at plan time.

`worker_pools` are not restricted to GPU zones: a pool may use any zone in
`zones`, and an unpinned pool uses `zones[0]`, like GPU pools. Each node clones
the snapshot of its own zone, which exists for every zone in `zones`. A pool
lives in one zone: spread workers over zones by defining one pool per zone.

Placement groups, by contrast, are opt-in per pool
(`worker_pools[*].placement`, `gpu_pools[*].placement`), default none, because there is no single
right answer: an inference pool wants `spread` so a host failure costs one
replica, a training pool wants `cluster` so collective operations stay on the
fastest interconnect. One group is created per pool, in the pool's zone.

#### The image is built once per zone, not once

`evroc_snapshot` is zonal: its schema has `region` and no `zone`, and it
inherits the zone of the disk in its `disk_ref`.
`disk-webhook.evroc.com` rejects a disk created from another zone's snapshot:

```
admission webhook "disk-webhook.evroc.com" denied the request: snapshot
"<name>" is in zone "a" but disk is in zone "c"
```

evroc's docs agree and name the only remedy: *"If you need disks in different
zones, you would need to create separate snapshots from disks in those
respective zones."* No snapshot-copy resource and no cross-zone disk clone
exists in the provider, so this is not something the module can route around.

Each zone therefore gets its own build host, its own `evroc_disk.image_target`
and its own `evroc_snapshot`, and each node clones the snapshot belonging to its
own zone. Three zones means three concurrent elemental builds. They run in
parallel, so wall-clock build time is roughly unchanged; the cost is compute.

Three details follow from that:

- **Build hosts come in two flavours.** `evroc_virtual_machine.jumphost` is
  `zones[0]`'s and holds the only public IP -- a default project allows three
  and the API VIP holds one, so one per zone would not fit.
  `evroc_virtual_machine.builder` is every other zone: no public IP (evroc
  gives VMs outbound internet access without one), reached by `ssh -J` through
  the jumphost, in a security group that admits SSH from the jumphost's private
  address and nothing else. They are two resources rather than one `for_each`
  because that security group must read the jumphost, and Terraform tracks
  dependencies per resource, not per instance -- one resource would be a cycle.
- **The builds are not verified identical.** Nothing coordinates them and OCI
  tags are mutable, so a tag that moves mid-build gives one zone different
  software with no visible signal anywhere. That cannot be caught by comparing
  the results: an elemental raw is not reproducible (fresh filesystem UUIDs, GPT
  GUIDs, build-time mtimes), so the sums differ on every multi-zone build
  whether or not anything moved. Pin digests rather than tags to prevent it.
- **The builders are ephemeral, and have to be.** A default project allows 20
  vCPU; three build hosts and three control-plane nodes do not both fit. So
  pass 2 destroys `evroc_virtual_machine.builder` and
  `evroc_snapshot.ai_factory` depends on that teardown, which puts it ahead of
  every node disk and every node. The jumphost stays -- with
  `control_plane_public_ip = false` it is the VPC's only inbound path. The
  trade: if pass 2 fails partway, recovering means `--rebuild` rather than a
  retry.

RKE2's etcd is latency-sensitive, and spreading its members across zones does
trade write latency for surviving a zone loss. evroc's zones are close enough
that this is the better default; a deployment that disagrees says so with
`zones = ["a"]`, which collapses every per-zone resource back to one -- one
build host and one snapshot.

### One load balancer, four listeners

evroc puts health checks and PROXY protocol on `evroc_lb_backend_service`, not
on the load balancer, so 6443, 9345, 80 and 443 share one `evroc_loadbalancer`
and one backend pool. With `ingress_controller = "traefik"` the 80/443 services
set `proxy_protocol = true` and health-check `/ping` on **8080**, because
Traefik's 80/443 entrypoints expect a PROXY header the health checker does not
send; with `ingress-nginx` they use a TCP check on the service port. The http
and https services, their routes and their listeners are all gated on
`ingress_controller != "none"` together, so nothing is left health-checking a
port nothing listens on.

Since the VIP is an ordinary public IP, `cluster.yaml` uses
`apiVIPMode: external`: no MetalLB, no kube-vip.

### CNI

`canal.yaml` is delivered by per-node Ignition straight into
`/var/lib/rancher/rke2/server/manifests/` on servers, **not** through
elemental's `kubernetes/manifests/` slot. That slot runs only after the API
server answers, by which time RKE2 has already installed the chart with default
values; for canal that lateness is permanent, because the values reach the
DaemonSet through a ConfigMap with no checksum annotation, so the reinstall
produces a byte-identical pod template, nothing rolls, and the wrong
`vethuMTU` stays in `/etc/cni/net.d/10-canal.conflist` for the node's life.
`"canal.yaml"` sorting before `"rke2-canal.yaml"` is what makes ours win.

`vpc_mtu` defaults to 8900, which is what evroc actually hands out over DHCP --
not the 1500 a VPC would conventionally use. `calico.vethuMTU` follows at
`vpc_mtu - 50`. A wrong value never errors: too high hangs large transfers and
TLS handshakes intermittently, too low silently costs throughput on every
pod-to-pod byte, since `configure-network.sh` applies it to the NIC directly.

### Build identity

`local.build_id` is the first 12 characters of `build_hash` from
`modules/elemental-config`. The hash covers the *rendered* config files (not the
`.tftpl` sources, so a changed variable renumbers the build even when no
template changed), the fetched AIF release manifest body, the sysext and
platform overrides, this module's factory script and `image_rebuild` when it is
above 0. Nothing time-based feeds it, so the id is stable across plans.
`terraform_data.build_identity` replaces the build hosts when the id changes, so
every new id starts a fresh factory run on each of them.

### Labels

Every evroc object the module creates carries `elemental-cluster`, `elemental-managed-by`,
`elemental-module` and `elemental-created` (UTC `YYYYMMDD-hhmmss` of the first
apply for the cluster name), plus `elemental-role`. The role values:

| Role | Objects |
|---|---|
| `network` | VPC, subnets |
| `lb` | load balancer, API VIP public IP, backend pool, backend services, L4 routes |
| `jumphost` | jumphost VM, boot disk, IP, security group |
| `builder` | per-zone build VMs, boot disks, security group |
| `image` | image-target disks, hotswap attachments |
| `control_plane` | CP nodes, their disks and IPs, placement groups, security group |
| `worker` / `gpu` | worker and GPU nodes, their disks and IPs, placement groups |
| `agent` | the security group shared by worker and GPU nodes |

`elemental-pool` is on every node and per-node object (`cp` for control planes).
`elemental-listener` (a port name from `modules/rke2-ports`: `kube_api`, `supervisor`,
`http`, `https`) is on the per-port backend services and L4 routes.

Objects whose contents belong to one image generation -- the image-target
disks, the node boot disks cloned from that generation's snapshot, and the
nodes themselves -- also carry `elemental-build` (`local.build_labels`). The network,
security groups and load balancer do not: they survive a rebuild untouched.

Two constraints worth knowing before editing this:

- **`elemental-build` cannot go in `common_labels`.** It derives from `build_hash`,
  which hashes `cluster.yaml`, which holds `local.api_vip` -- and that public IP
  wears `common_labels`, so Terraform rejects the configuration with a cycle.
- **`evroc_snapshot` accepts no labels at all** -- the provider exposes only
  `system_labels` on it. A snapshot is identifiable by name only, which is why
  `local.snapshot_names` spells out cluster, build timestamp and zone.

`var.tags` is merged in and cannot use the `elemental-` prefix or
contain `/` in a key (the evroc API rejects it). It is validated against
Kubernetes label syntax at plan time, because evroc's API enforces it and an
invalid value otherwise fails the apply across every resource at once.

### Plan-time checks

All hard-fail at `terraform plan` (conditions in `network.tf`, `availability.tf`):

- `zones` entries are `a`, `b` or `c`; `image_ids` covers every zone in use;
  `image_id` is rejected (snapshots are zonal).
- `vpc_cidr` is a /16 to /24 block (one subnet per zone, 4 extra prefix bits);
  `vpc_mtu` is 1330-9000.
- Pool `kind` is `vm`, `placement` is `spread`, `cluster` or null,
  `instance_type` looks like a compute profile and every pool zone is in `zones`;
  GPU pools sit in a GPU zone and `worker_pools` use no GPU flavor.
- Every requested flavor is offered, and the peak vCPU, memory and public-IP
  demand fits the organization quota. Details and the numbers:
  [docs/providers/evroc.md](../../docs/providers/evroc.md#quota).

Access: the load balancer keeps the client address, so the control-plane group
filters its listeners. 6443 follows `api_cidrs` (plus the VPC), 9345 is open to
`0.0.0.0/0`, 80/443 follow `ingress_cidrs`; `admin_cidrs` filters SSH to the
jumphost and nodes and reads of the build-status relay.

### Things in the image that look wrong and are not

Four constraints in `modules/elemental-config/templates/elemental/butane.yaml.tftpl` are load-bearing
and each has a comment saying so:

- Helper scripts live under `/var/lib/elemental`, never `/opt` -- `/opt` is
  read-only in the initrd and a failed write there drops the whole Ignition
  files stage into a dracut emergency shell.
- Units invoke them as `ExecStart=/usr/bin/bash /var/lib/elemental/foo.sh`. A
  direct `ExecStart` fails 203/EXEC with no AVC in dmesg, because Ignition
  labels those files `var_lib_t` and the denial is dontaudited.
- File modes are decimal (`384`, `416`, `493`). Elemental round-trips the YAML
  through `map[string]any`; a leading-zero octal does not survive.
- `local-path-prep.service` uses `mkdir -pZ`. Without `-Z` the directory
  inherits `usr_t` from `/opt` and the provisioner pod cannot write to it.

Similarly, `iscsi-prep.sh` (shipped only with `suse-storage`) exists because
systemd-sysext merges `/usr` and `/opt` and nothing else: the Longhorn
extension brings `iscsid` but no `/etc/iscsi`. The symptom is nowhere near
iSCSI -- the PVC binds, replicas schedule, and the consuming pod hangs in
`ContainerCreating` with `AttachVolume.Attach ... DeadlineExceeded`.

And note the schema asymmetry between `release.yaml`, which keys extensions as
`- extension: <name>`, and the release *manifest*, which uses
`systemd.extensions[].name`. Getting it wrong yields "requested systemd
extension(s) not found".

## Files

| File | Contents |
|---|---|
| `network.tf` | VPC, per-zone subnets, the standalone API VIP, per-zone placement groups, plan-time input checks (preconditions on `evroc_vpc.this`) |
| `firewall.tf` | jumphost / builder / control-plane / agent groups |
| `loadbalancer.tf` | one LB, one backend pool, up to four (listener, route, service) sets |
| `availability.tf` | plan-time data sources for offered flavors and the organization quota (the checks are conditions on them and on `evroc_vpc.this` in `network.tf`) |
| `build.tf` | per-zone blank disks, jumphost + builders, hotswap attachments, build-status wait |
| `image.tf` | build id, per-zone `evroc_snapshot`, `effective_snapshot_ids`, config module call, build script |
| `control-plane.tf`, `agent-nodes.tf` | node disks, public IPs, VMs (agent nodes serve `worker_pools` and `gpu_pools`) |
| `locals.tf` | provider defaults, labels, zone and subnet layout, node lists |
| `outputs.tf` | the common output set, `next_steps` and `provider_details` |
| `variables.tf` | evroc-only variables; the common ones are the symlinked `variables-common.tf` |
| `templates/factory-*.sh.tftpl` | evroc hooks of the build script (shared `modules/image-factory`), run on every build host |
| `templates/cloud-init.yaml.tftpl` | user data of the jumphost and builders: config directory, build script, status relay |
| `tests/` | `terraform test` files with `mock_provider` (outputs, quota checks) |
| `templates/status-relay.py` | build-status relay on the jumphost: build hosts PUT, the operator GETs |
| `templates/elemental/network/` | `configure-network.sh` (initrd hook); the rest of the elemental config directory comes from `modules/elemental-config` |
| `modules/evroc/scripts/wait-for-image.sh` | operator-side HTTP poll of the status relay |

## Inputs and outputs

Generated by `make docs`; do not edit between the markers.

<!-- BEGIN_TF_DOCS -->
## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| admin\_cidrs | CIDRs allowed to reach the jumphost and nodes over SSH. No default: an empty list locks everyone out. | `list(string)` | n/a | yes |
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
| image\_ids | Existing evroc snapshots to boot instead of building images, keyed by zone; snapshots are zonal, so it must cover every zone in use. Empty builds one image per zone. | `map(string)` | `{}` | no |
| image\_ready | Set by deploy.sh for the second pass, once the per-zone image builds have finished. false attaches the blank image disks to the build hosts; true detaches them and snapshots them. | `bool` | `false` | no |
| image\_rebuild | Rebuild counter mixed into the image build hash. deploy.sh --rebuild bumps it in rebuild.auto.tfvars.json; do not set it by hand unless you know why. | `number` | `0` | no |
| image\_target\_disk\_gb | Size in GB of the blank disk each build host writes the raw image onto. Must be at least image\_disk\_size. | `number` | `32` | no |
| ingress\_cidrs | CIDRs allowed to reach the ingress on 80/443, which serves the Rancher UI. Narrow it for clusters that are not public. | `list(string)` | <pre>[<br/>  "0.0.0.0/0"<br/>]</pre> | no |
| ingress\_controller | RKE2 ingress-controller setting. Only traefik adds a HelmChartConfig. | `string` | `"traefik"` | no |
| jumphost\_disk\_size\_gb | Root disk size in GB of the jumphost. Null uses the provider default; providers whose plans fix the disk reject a value. | `number` | `null` | no |
| jumphost\_image | OS image (AMI, image name or OS ID) of the jumphost. Null uses the provider default (an openSUSE Leap image). | `string` | `null` | no |
| jumphost\_instance\_type | Machine type, flavor or plan of the jumphost that builds the image and serves as SSH bastion. Null uses the provider default. | `string` | `null` | no |
| jumphost\_username | Login user of the jumphost. Empty makes the jumphost root-only. | `string` | `"suse"` | no |
| keep\_build\_artifacts | Keep the intermediate build artifacts (raw image, build disks) after the image is registered. No effect on vultr, which builds on the jumphost. | `bool` | `false` | no |
| node\_user\_password\_hash | Crypt hash for node\_username. | `string` | n/a | yes |
| node\_username | Unprivileged login account created on every node. | `string` | `"suse"` | no |
| nvidia\_api\_key | NVIDIA NGC API key. Optional, recommended with aif-operator; unset omits the nvidia credentials block. | `string` | `null` | no |
| nvidia\_username | NGC username paired with nvidia\_api\_key; NGC uses the literal $oauthtoken for API-key auth. | `string` | `"$oauthtoken"` | no |
| permit\_root\_ssh | Allow SSH logins as root and install ssh\_authorized\_keys for it. Debug toggle. | `bool` | `false` | no |
| project | evroc project to create resources in. Null uses the project of the provider's configured context. | `string` | `null` | no |
| rancher\_bootstrap\_password | Rancher initial admin password; a random one is generated when null. | `string` | `null` | no |
| rancher\_hostname | Hostname of the Rancher ingress. Null selects a provider-specific default. | `string` | `null` | no |
| region | Provider region or location. Required by providers that have no region default; the provider module checks it. | `string` | `null` | no |
| root\_password\_hash | Crypt hash for the root account (for example from `openssl passwd -6`). | `string` | n/a | yes |
| ssh\_authorized\_keys | SSH public keys for node\_username, and for root when permit\_root\_ssh is set. | `list(string)` | n/a | yes |
| suse\_registry\_password | SUSE registry password, paired with suse\_registry\_username. | `string` | `null` | no |
| suse\_registry\_username | SUSE registry username. Optional, set together with suse\_registry\_password; recommended with aif-operator. | `string` | `null` | no |
| suse\_storage\_nodes | Where the suse-storage (Longhorn) disks live: roles (control\_plane, worker for all worker\_pools, gpu for all gpu\_pools) and/or pool names, e.g. ["control\_plane", "storage"]. At least three such nodes are required. | `list(string)` | <pre>[<br/>  "control_plane"<br/>]</pre> | no |
| sysext\_image\_overrides | Beta workaround: per-extension OCI image overrides written into the release manifest, keyed by extension name. See docs/workarounds.md. | `map(string)` | <pre>{<br/>  "suse-storage": "registry.suse.com/beta/uc/longhorn:5.279-4.13"<br/>}</pre> | no |
| tags | Extra tags or labels on every resource that supports them. Keys must not use the elemental- prefix, which the module manages. | `map(string)` | `{}` | no |
| vpc\_cidr | IPv4 CIDR of the cluster network, from which subnets are derived; null uses the provider default. Must not overlap the RKE2 cluster (10.42.0.0/16) or service (10.43.0.0/16) CIDRs. | `string` | `null` | no |
| vpc\_mtu | MTU of the cluster network interfaces; the pod MTU is derived from it. Null uses the provider default. | `number` | `null` | no |
| worker\_pools | Worker pools without GPUs keyed by pool name, with the same fields as gpu\_pools. Hostnames are <cluster\_name>-<pool>-NN, so keys must not collide with gpu\_pools keys. | <pre>map(object({<br/>    instance_type = string<br/>    count         = optional(number, 1)<br/>    disk_size_gb  = optional(number)<br/>    zone          = optional(string)<br/>    public_ip     = optional(bool, false)<br/>    kind          = optional(string, "vm")<br/>    placement     = optional(string)<br/>  }))</pre> | `{}` | no |
| zones | Zone suffixes the cluster spans (for example ["a", "b", "c"]); control planes are spread round-robin. Empty uses the provider default; providers without zones accept at most one entry. | `list(string)` | `[]` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| api\_host | DNS name of the Kubernetes API, present in the API server certificate SANs. |
| api\_vip | Public IP of the load balancer that fronts the Kubernetes API. |
| build\_status | Build-status relay URL and the build hosts (private IPs reachable via the jumphost) while an image build runs; null afterwards. |
| cluster\_name | Cluster name, the prefix of every node hostname. |
| egress\_ips | Public source IPs of nodes that have one. Nodes without a public IP use platform egress addresses that are not exposed. |
| image | Image build id and the snapshot id per zone (null before the build completes). |
| ingress\_endpoint | https:// URL of the ingress address (the same load balancer IP as the API). Null when ingress\_controller is "none". |
| jumphost | Jumphost addresses and SSH user; the only inbound admin path. Addresses are null until it exists. |
| kubernetes\_api\_endpoint | Kubernetes API URL on api\_host, served by the load balancer at api\_vip. |
| network | VPC CIDR and the per-zone subnet CIDRs. |
| next\_steps | Post-deploy hints; contains no secrets. |
| nodes | Cluster nodes keyed by hostname: role, pool, init, zone, private\_ip, public\_ip, instance\_type, id, ssh\_user. Empty until nodes are deployed. |
| provider | Provider name, for tools that dispatch on it. |
| provider\_details | evroc-specific data: quota and GPU demand, security groups, image target disks, control-plane FQIDs, builder addresses. |
| rancher\_bootstrap\_password | Initial Rancher admin password. Null when Rancher is not enabled. |
| rancher\_hostname | Hostname Rancher's ingress serves. Null when Rancher is not enabled. |
| rancher\_url | Rancher UI URL. Null when Rancher is not enabled. |
| region | evroc region the cluster runs in. |
<!-- END_TF_DOCS -->

## Security

Everything sensitive this module takes -- both password hashes, the AppCo and
SUSE registry credentials, the NGC key, and the generated RKE2 join token and
Rancher bootstrap password -- is stored in Terraform state in plaintext **and**
baked into the elemental image. So the snapshot is a credential in its own
right: anyone who can clone it has the join token and the root password hash,
with no access to state required. Restrict read access to snapshots and disks
in the project the same way you restrict `terraform.tfstate`.
