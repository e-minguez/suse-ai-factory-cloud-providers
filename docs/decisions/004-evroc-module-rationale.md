# 004 - evroc module rationale

## Status
Accepted.

## Context
The evroc module carried long code comments explaining platform behaviour and
graph-shape choices. They moved here; code comments now state what and the
non-obvious constraint only (see `CLAUDE.md`, "Writing style").

## Decision and rationale

### One image build per zone
`evroc_snapshot` has a `region` attribute and no `zone`, but it takes the zone
of its `disk_ref` disk. The disk webhook rejects a disk created in zone X from
a snapshot whose source disk is in zone Y (`snapshot "<name>" is in zone "a"
but disk is in zone "c"`). The platform docs state that snapshots are zonal
and that disks in other zones need separate snapshots. The provider has no
snapshot copy and no cross-zone disk clone. `build.tf` therefore creates one
build host, one image-target disk and one snapshot per zone. A single-zone
cluster has one element in each `for_each`. Each build host is pinned to its
zone because `evroc_hotswap_disk_attachment` only joins a disk to a VM in the
same zone. Every zone's snapshot is built from the same inputs; content
equality is not verified.

### Jumphost and builders are two resources
The builders' security group admits SSH from the jumphost's private address,
so it reads `evroc_virtual_machine.jumphost`. Terraform tracks dependencies per
resource, not per `for_each` instance, so builders as extra instances of the
jumphost resource would make it depend on a group that depends on it (cycle).
The same holds for the jumphost user_data and the builder user_data (the
builders need the jumphost's private IP for the status relay), hence two
security groups and two user_data locals.

### Build hosts and public IPs
Only `zones[0]` has a public IP; other build hosts are reached through it.
A default project allows three public IPs and the API VIP holds one. VMs
have outbound internet access without a public IP, which is enough for
`podman pull`. The jumphost outlives the build (with
`control_plane_public_ip = false` it is the only inbound path), so its role
label is `jumphost`, not `build-host`.

### Builders are destroyed on pass 2
A default project has 20 vCPU: three build hosts and three control-plane
nodes do not fit together. `evroc_snapshot.ai_factory` lists the builders in
`depends_on` so their teardown happens before nodes are created; otherwise the
VM webhook rejects nodes on quota. Builder boot disks share the builders'
lifetime (`builder_boot`, keyed on `builder_zones_active`). Sharing one disk
resource with the jumphost left orphaned Leap disks after pass 2. If pass 2
fails partway the builders are gone and their disks cannot be inspected;
recovery is `--rebuild`. That is accepted because every zone has reported
`done` for the current build id before pass 2 starts.

### Image-target disks outlive the builders
The disks hold the finished image and are the snapshot source. A snapshot
survives deletion of its source disk (verified 2026-09-22), but booting a disk
cloned from such a snapshot is untested. Pass 2 therefore keeps the disks, and a
third apply deletes them unless `keep_build_artifacts` is true.
`!var.image_ready` keeps them unconditionally while a build can still write.
Their name is stable across rebuilds, so the `elemental-build` label
(`build_labels`) is the only marker of the image generation.

### Hotswap attachment
`evroc_hotswap_disk_attachment` ties a disk's visibility to a VM to the
resource existing. Pass 1 (`image_ready = false`) attaches so the factory can
`dd`; pass 2 destroys the attachment, which is the detach. A disk attached to
a running VM is not snapshotted. Destroying the attachment and creating the
snapshot happen in one apply; `depends_on` on the snapshot is a hint, since
its documented meaning orders destroys after dependents. Every pass-2 apply so
far detached first. If the platform rejects the snapshot because the disk is
still attached, the apply fails after the attachment was destroyed and a
re-run succeeds. The deterministic alternative is a targeted apply that
detaches first.

### `terraform_data.image_written` stays after pass 2
It is not gated on `image_ready`. If an image-affecting input changes between
the passes, `build_id` changes and the disks hold an image from stale
configuration. With the resource kept, the pass-2 plan shows it being replaced
above the snapshots; applying it fails at once (`IMAGE_READY=true`, nothing to
wait for) instead of snapshotting the stale image. One resource covers all
zones so they share one timeout and one progress stream. `triggers_replace`
(not `input`) makes the provisioner run again on a new build id; `input`
changes update in place and do not re-run `local-exec`.

### Snapshot disk_ref and lifecycle
`disk_ref` uses `try()` because `evroc_disk.image_target` has no instances
once `keep_build_artifacts` reclaims them; a missing `for_each` key is a
plan-time error. The fallback string equals the real fqid, built from a
sibling disk's fqid prefix because `var.project` defaults to null and the
provider supplies the project. Keeping the disk reference inside `try()`
preserves the disk-before-snapshot edge. `ignore_changes = [disk_ref]`
guards the immutable field: a mismatch would delete the snapshot every node
disk was cloned from. `evroc_snapshot` has no `user_labels` attribute, so the
name (cluster, build id, zone) is its only handle.

### Plan-known node gates
`snapshot_expected = length(var.image_ids) > 0 || var.image_ready` is used
for node `for_each` instead of testing snapshot ids. Snapshot fqids are
unknown on the apply that creates them; a gate derived from them makes the
whole map, keys included, unknown, so `for_each` fails on every node
resource, also during `terraform destroy`. `effective_snapshot_ids` uses a
conditional, not `coalesce()`, because `coalesce()` errors on all-null
arguments (image not built yet). Zone assignment of control-plane nodes is
round-robin by node index so raising the count only appends nodes; moving an
etcd member means recreating it. Node maps are keyed by hostname for the same
reason.

### Labels
`common_labels` (`elemental-{cluster,managed-by,module,created}`) go on every
object, plus `elemental-role` from the common vocabulary, `elemental-pool` on
nodes and per-node objects and `elemental-listener` on per-port LB objects.
`created` is the UTC `YYYYMMDD-hhmmss` of the first apply for the cluster name
(`time_static`, triggered by `cluster_name` only). `build_labels` adds
`elemental-build` for objects whose content comes from one build (image-target
disks, node boot disks, nodes). It is not in `common_labels` because the build id depends on `cluster.yaml`, which holds
the API VIP, which wears `common_labels`. It is not applied to VPC, subnets,
security groups, public IPs or the load balancer, which survive a rebuild.
Label values follow Kubernetes rules (63 characters, no colons); `var.tags`
is validated against the same shape, cannot contain `/` in a key (the evroc API
rejects it) and cannot use the `elemental-` prefix.

### Provider pin
`evroc` `~> 0.9.4`. 0.9.4 is the first release where `evroc_loadbalancer`
accepts `backend_network`. Without it the load balancer attaches to the
default VPC and forwards nothing while every object reports Ready. The
`~>` constraint keeps breaking changes (0.8.0 removed
`evroc_permission_set`) behind a deliberate bump.

### Load balancer
- One load balancer serves API, supervisor and ingress. Health check type and
  PROXY protocol are per backend service, so one service per port.
- `backend_network` forces replacement; changing `vpc_cidr` or `zones`
  recreates the load balancer and the VIP stops answering meanwhile. One subnet
  per zone must be listed or that zone's backends are unreachable.
- The provider declares `ip_protocol_selection`, the health check tuning
  fields and `http.expected_statuses` Optional without Computed. Absent
  values plan as null, the server default returns on read, and the diff never
  converges. The perpetual update of all backend services races the LB
  controller (`409 Conflict`). The defaults are set explicitly; do not remove
  them without checking that a second plan is empty.
- `health_check.target_port` must not be null: the API stores 0, the check
  never passes, and the LB resets every connection (`unexpected eof while
  reading`). State shows `target_port = 0`.
- The pool is empty on the first apply; RKE2 servers retry the 9345 join until
  a backend answers.

### Security groups
- Cluster-internal rules cite `vpc_cidr`, not another group: a group cannot
  reference itself and two groups referencing each other form a cycle.
- The jumphost SSH rule for nodes is the jumphost's `/32` (not `vpc_cidr`),
  so node-to-node SSH is not opened. Its value is unknown until the jumphost
  exists; it is a rule value, not a key, so the rule set stays plan-known.
  Without it, nodes without public IPs have no SSH path since `admin_cidrs`
  never matches a VPC-internal source. The jumphost group has no such rule.
- The status relay rules exist only while a build can run
  (`image_ready = false`). The relay accepts PUT only from `vpc_cidr`; the admin
  rules grant read access.
- Builders get no `admin_ssh_rules`: they have no public IP.
- One agent security group is shared by all worker and GPU pools, so it carries no `pool` label.

### Network
- `evroc_vpc`, load balancer, backend pool, public IP and security group are
  regional; subnet, disk, VM, placement group and snapshot are zonal.
- Subnets are keyed by zone name, so removing a zone destroys only its subnet.
  CIDRs come from `cidrsubnet` in zone-list order; reordering `zones`
  renumbers and replaces subnets, so append zones.
- `evroc_public_ip.cluster` has no dependencies. The image bakes in the VIP
  (`api_host`, `tls-san`); a VIP known only after the load balancer would need
  nodes that need the image. Its role label is `lb`; it counts against the
  three-address quota.
- Control-plane placement group is `spread`, one per zone. It matters once
  `control_plane_count` exceeds the zone count. GPU placement groups are per
  pool and zone; inference and training want opposite strategies.

### GPU nodes
- A snapshot clone could not carry `diskImageRef`, which GPU flavors required
  (`Ready: disk is missing DiskImageRef`). The platform lifted this on
  2026-09-23 and a `gn-l40s.s` node boots the module's snapshot. Building GPU
  workers from a stock image and joining them separately was not implemented:
  it would add a second node path outside the immutable image.
- Zone is per pool (GPU VMs are admitted in zone `a` only, checked at plan
  time). Placement is per pool and defaults to none. Public IP is per pool and
  defaults to false: VMs reach the internet through platform egress, which the
  GPU operator needs to pull driver containers at runtime.
- The UEFI label is duplicated on control-plane and GPU VMs, not shared, since
  the resources differ elsewhere.

### UEFI label
The Elemental image is EFI-only. Without `compute-experimental-features-UEFI`
the VM boots BIOS, finds no bootloader and stays "Running" without answering
anything. The prefix marks a feature flag that can change without notice.
The build hosts boot stock platform images and do not need it.

### Build-status relay
evroc has no serial console, so build progress is relayed over HTTP: each
build host `PUT`s a one-line status to `templates/status-relay.py` on the
jumphost, and `modules/evroc/scripts/wait-for-image.sh` (run by
`terraform_data.image_written`) polls it with `GET`. The relay is the one
accepted Python on instances; it targets Python 3.6 because the jumphost image
(openSUSE Leap 15.6) has no `ThreadingHTTPServer`. PUT is accepted from
`vpc_cidr` and the jumphost's loopback only, GET from `admin_cidrs`, and the
security-group rules disappear on pass 2. Status lines carry the build id, so
a line from an earlier build counts as stale.

### Quota
Availability and organization quota (vCPU, memory, public IPs) are hard
failures at plan, as preconditions on `evroc_vpc.this` (every node depends on
it) and postconditions on `evroc_compute_profiles`. The demand is the peak over
the passes, since builders are gone before nodes exist; usage by other
workloads is not read.

GPU quota is counted in GPUs, not VMs: the flavor size is the GPU count
(`gn-l40s.s` 1, `.m` 2, `.l` 4). The provider has no GPU quota data source, so
`count * gpu_quantity` is exposed as `gpu_quota_request`, summed per model
because the quota is held per model.

### user_data limits
The platform limit is 1 MB (a KubeVirt field). Nodes are checked against
768 KiB. Build hosts carry the config directory gz+base64 and use a 32 KiB
tripwire, about twice a known-good payload, to catch a template rendering the
directory twice. `nonsensitive()` is applied to the length only.

### Templates
- `configure-network.sh` (initrd hook): evroc VMs are expected to have one
  NIC; a public IP is 1:1 NAT on it. The script counts NICs from
  `/sys/class/net/*/device` and does nothing on any other count. For one NIC it
  sets MTU with `ip link` and disables IPv6 through `/proc`, with no nmstate
  document: applying one makes NetworkManager build a new profile and send a
  fresh DHCP DISCOVER instead of renewing the lease. The hook sandbox mounts
  everything read-only except `/proc`, `/sys` and `/dev`, and the initrd is
  not guaranteed to have `tr`, `basename`, `dirname`, `mktemp`, `jq` or
  `python3`, so it uses bash builtins only. A NIC with no carrier is reported
  in the log; the script cannot fix it and exits normally so a shell remains for
  diagnosis.
- `vpc_prefix` is only logged next to the held address, never enforced.
