# Plan: Exoscale provider

Status: evaluation complete (spike tests 2026-10-05/06, de-fra-1), nothing
implemented. Provider checked: `exoscale/exoscale` v0.74.2 (2026-10-02).
Design decisions: [ADR 008](../decisions/008-exoscale-module.md).
Implementation order: section 11. Items still marked **[spike]** below were
answered later in the same section or in section 10.

## 1. Verdict

Feasible, with two design problems to solve first and some convention changes:

| # | Topic | Impact | Section |
|---|---|---|---|
| B1 | An NLB service can only target an **instance pool**; every pool member gets the same user_data | Decided: control-plane pool grown 1 → N over two passes, hostname from metadata | 4 |
| B2 | Private instances (`private = true`) get no 169.254.169.254 metadata, and the Ignition `exoscale` provider reads only that endpoint | **Confirmed by spike S2**: private Elemental node → "Failed to start Ignition (fetch)", emergency mode. Every node needs a public IPv4 | 5 |
| B3 | ~~Label values must start with a non-digit (docs)~~ | **Resolved by spike S5**: the API accepts `20261005-120000` on private network, NLB, instance pool and instances; convention unchanged | 7 |
| B4 | No TF data source for instance types or quotas; quota API needs signed requests | Changes how the plan-time checks work | 8 |
| B5 | Custom templates: qcow2 from a public URL, MD5, **one per zone** | Image pipeline is close to vultr's, plus a conversion step | 3 |

All five were settled by the spike tests (section 10); the design is in
ADR 008.

## 2. Platform facts and how they map to the repo

| Concept | aws | vultr | evroc | Exoscale |
|---|---|---|---|---|
| Image | S3 + snapshot import → AMI | `vultr_snapshot_from_url` | `dd` to disk + `evroc_snapshot` per zone | `exoscale_template` from URL, **per zone**, qcow2, MD5, `boot_mode = "uefi"` |
| `ignition.platform.id` | `aws` | `vultr` | `proxmoxve` | `exoscale` (supported by Ignition; reads userdata from 169.254.169.254) |
| user_data limit | 16 KiB | 32 KiB | 768 KiB | 32768 chars **base64** → ~24 KiB payload; provider passes already-base64 input through, so `base64gzip()` works |
| Private net | VPC subnets | VPC | VPC subnets | `exoscale_private_network` (L2, zone-local, managed DHCP, **MTU 1500**). `exoscale_vpc*` exists but is beta and has no instance attachment in TF |
| Egress w/o public IP | NAT GW | NAT GW | yes | **no** (no managed NAT) |
| LB | NLB, instance targets | inline backends | backend pool | `exoscale_nlb` + `exoscale_nlb_service`, **instance pool targets only**, max 5 NLBs/account |
| Firewall | SG | firewall groups | SG | SG; stateful; **not applied inside private networks** |
| Labels | tags | `k=v` strings | labels | `labels` on instances, pools, privnets, NLB, EIP; **none on templates, SGs, anti-affinity groups, SSH keys** |
| Zones | AZs in region | single location | zones in region | zone = region; instances, pools, privnets, templates are zone-scoped |
| GPU | instance types | vcg/vbm plans | `gpu_zones` | per-zone families, quota 0 by default (support ticket) |
| Pricing | API | API | JS chunk | public JSON: `https://portal.exoscale.com/api/pricing/opencompute` (no zone dimension) |

Consequence for common variables: `region` = Exoscale zone (e.g. `de-fra-1`),
`zones` must be a single element or null (reject more with a precondition, like
vultr). Multi-zone HA is out of scope: privnets and pools cannot span zones.

## 3. Image pipeline (vultr pattern + qcow2)

1. Jumphost (stock openSUSE Leap / SLES template on Exoscale) runs
   `factory-common.sh` unchanged: prereqs → customize → raw.
2. `hook_deliver_raw`: `qemu-img convert -f raw -O qcow2 -o preallocation=off`,
   `md5sum`, serve with `python3 -m http.server` under `random_id.serve_path`
   (already an accepted Python exception for vultr; extend the CLAUDE.md list).
   **[spike]** whether raw is accepted (TF docs say "qcow2/raw", product docs say
   qcow2 only). If raw works, skip the conversion.
3. SG rule opens tcp/80 on the jumphost only during the import (vultr
   `image_import_port_open` pattern).
4. `terraform_data.image_served` polls a `wait-for-image.sh` that also fetches
   the MD5 (or the hook writes it into a file served next to the image).
   **Problem**: `exoscale_template.checksum` is required at plan time and the
   MD5 is only known after the build. Options:
   - a) Pass 2 reads the MD5 via `data.http` from the jumphost (fits a 2-pass
     design anyway);
   - b) `data.http` in pass 1 with `depends_on = [terraform_data.image_served]`
     — the data source is deferred to apply; `checksum` is then unknown at
     plan, which is allowed for a resource argument. **Preferred, [spike].**
5. `exoscale_template` per zone (one zone in practice), `boot_mode = "uefi"`,
   `password_enabled = false`, `ssh_key_enabled = false`, name
   `<cluster>-<build_id>`. Registration took 16 s in spike S1; keep a generous
   create timeout anyway.
6. Tear down the SG rule afterwards (pass 2, as vultr).

Every new input (qcow2 conversion flags, serve path logic) lives in the factory
hooks and is covered by `extra_build_inputs = {factory = script_hash}`.

Spike S1 (2026-10-06, de-fra-1):
- **Raw rejected**: "The magic QCOW2 number should be 1363560955 … version
  should be 2 or 3". qcow2 conversion on the jumphost is mandatory.
- **qcow2 virtual size must be 10–1000 GB**: the shared default
  `image_disk_size = "8G"` fails. Chosen approach (user): keep the raw small
  (8G or less) and grow the qcow2 with `qemu-img resize` to 10 GiB in the
  deliver hook. Metadata-only, so build and transfer stay fast; the platform
  grows the disk to `disk_size` at boot anyway (GPT backup header relocation is
  needed in both cases, checked by S3 root growth).
- MD5 read with `data.http` deferred by `depends_on` (apply time) works; the
  template rejection came back within seconds, so bad images fail fast.
- **qcow2 accepted**: `boot_mode = "uefi"`, 10 GiB virtual, 887 MB file,
  registered in **16 s**. With `components = []` a 5G raw builds (customize
  ~30 s, jumphost → served ~2 min). Exoscale default `image_disk_size = "5G"`
  (decided); the first e2e deploy with the full component set confirms it.

Spike S3 (Elemental on Exoscale, standalone control plane + pool agent):
- Ignition with `ignition.platform.id=exoscale` applies hostname,
  `runtime.env` and SSH keys (public instance).
- Root grows to `disk_size` (100 GB disk → 98 GB root), GPT relocation fine.
- NICs are `ens3` (public) / `ens6` (privnet); NetworkManager DHCPs the privnet
  NIC with its default "Wired Connection"; MTU 1500, pod MTU 1450.
- RKE2 server Ready with `node-ip` on the privnet; the pool member joined as an
  agent over the privnet (INTERNAL-IP privnet). On this boot write-node-ip saw
  both NICs (Elemental boots slower than Ubuntu); keep the wait mode as
  hardening against the hot-plug race seen in spike A.
- user_data per node 415–883 bytes: far below the ~24 KiB limit.

Spike S2 (private Elemental node, `private = true`): console shows
"Timed out waiting for device /dev/disk/by-label/ignition", "catalyst-prepare:
No config source found", "Failed to start Ignition (fetch)", emergency mode.
The NoCloud drive of private instances is not an Ignition source. Public IPv4
on every node is required; precondition rejects `public_ip = false`.

`runtime.env` is read only by `/usr/bin/elemental3ctl`, in the initrd
firstboot stage after Ignition (no systemd unit references it);
`k8s-config-installer.service` (named in write-node-ip's `Before=`) is
`not-found` in this image (stale reference, harmless; separate cleanup). In
the pool design `runtime.env` is static per pool, so only the hostname is
dynamic. Decision: a oneshot (`After=network-online.target`,
`Before=rke2-server.service rke2-agent.service`, write-node-ip pattern) reads
metadata `local-hostname`, sets the hostname and writes
`node-name: <name>` to `/etc/rancher/rke2/config.yaml.d/98-node-name.yaml`,
so RKE2 uses it regardless of what `elemental3ctl` rendered.

Found while building spike B:
- `exoscale_compute_instance.user_data` updates **in place** (no ForceNew), so
  a new build would not re-run cloud-init on the jumphost. The jumphost needs
  `replace_triggered_by` on the build-keyed `random_id` (serve path).
- `qemu-img` comes from package `qemu-tools`; `image-factory`'s
  `extra_packages` requires package name == command name, so install it in
  the `pre_build` hook (or extend `image-factory` with a package → command map).

Alternatives rejected: SOS presigned URL (instances must not read/write object
storage; only aws has an exception), snapshot → `:promote` (not in TF, and
block-storage snapshots cannot be promoted, so no evroc-style `dd`).

`build_status.method` = `http`.

Root growth and hostname were open questions here; both are answered in
spike S3 above (root grows; standalone nodes take `/etc/hostname` from
Ignition, pool members from metadata).

## 4. Load balancing (B1)

Per-node Ignition (`modules/elemental-config/ignition.tf:6-8`) writes
hostname, role and the `init` flag. An instance pool shares one user_data, so
nodes behind an NLB cannot have per-node config without changes.

### Decision: control-plane instance pool, grown from 1 to N

Only the control planes need the NLB: on every provider the ingress LB
(80/443) targets the control planes too (`modules/aws/loadbalancer.tf:261`,
vultr shares `lb_backend_instance_ids`). So:

- **Control planes**: one `exoscale_instance_pool`, target of both NLB
  services (API 6443/9345, ingress 80/443). `anti_affinity_group_ids` spreads
  members (max 8 per group → precondition on `control_plane_count`).
- **Workers / GPU**: standalone `exoscale_compute_instance`, per-node Ignition
  unchanged.

Per-node pieces of the pool config:

| Piece | In the pool |
|---|---|
| `NODETYPE=server`, canal manifest, Longhorn label | fixed per role |
| node-ip | `write-node-ip.sh` picks the privnet IP (pool members get DHCP, no static IPs) |
| `/etc/hostname` | oneshot baked into the image (via `extra_config_files`, feeds `build_hash`) reads metadata `local-hostname`, ordered `Before=` the unit that consumes `runtime.env` |
| `IS_INIT_NODE` | pass-dependent user_data, see below |

`elemental-config` change: a node entry flag (e.g. `hostname_from_metadata`)
that skips `/etc/hostname`, with a test. Shared module, small change.

Member names are `<instance_prefix>-<5 chars of pool ID>-<random>` (not
ordinal). With `instance_prefix = "<cluster>-cp"` hostnames are
`<cluster>-cp-ab8fb-xbedt`: documented exception to `<cluster>-cp-NN` in
`docs/conventions.md#naming`; prefix max 30 chars → precondition on
`cluster_name` length.

### Init without separate clusters

Only the init config can bootstrap, and it only exists while the pool has one
member:

| | Pool user_data | Size |
|---|---|---|
| Pass 1 | init (`IS_INIT_NODE=true`, no `server:`) | 1 |
| Pass 2+ | join (`server: https://<nlb_ip>:9345`) | `control_plane_count` |

A joiner never bootstraps; it retries until the supervisor answers.

- **Gate end of pass 1**: `terraform_data.cp_init_ready` runs
  `scripts/wait-for-cp-init.sh`, polling `https://<member public IP>:9345/ping`
  from the jumphost (SSH; 9345 allowed from the jumphost SG only). Terraform
  exposes no privnet IP for pool members (`instances[*]` has `id`, `name`,
  `public_ip_address`, `ipv6_address`), so the `nodes` output and the gate use
  public IPs. Pass 1 only finishes
  once the supervisor answers. `deploy.sh` then pins `cp_initialized = true` in
  `pass2.auto.tfvars.json` (evroc `image_ready` pattern).
- **Terraform guards**: `user_data = var.cp_initialized ? join : init`;
  precondition `size > 1` requires `cp_initialized`. Once pinned, the init
  config never comes back.
- **Pool replacement is the real risk**: if a `user_data` change forces
  replacement of `exoscale_instance_pool`, pass 2 destroys the cluster.
  **[spike, first]** in-place update, new user_data only for new members. Plus a
  `TF_PLAN_HOOK` (vultr pattern) that fails when the control-plane pool would be
  replaced and `cp_initialized = true`. Ignition runs only on first boot, so
  existing members are unaffected even if metadata serves the new user_data.
- **Failure cases**: pool replaces the init member during pass 1 → re-inits,
  the size-1 cluster is gone anyway. Replacement after pass 2 → joins via NLB.
  `control_plane_count = 1` → single pass, stays on init config.

### Scale-down

The pool removes the **oldest** members first (the init node first) and does
not remove etcd members. `docs/scaling.md`: drain, `etcd member remove`, then
the pool `evict` action on the chosen member, then lower
`control_plane_count`.

### Rejected

- Standalone init `cp-01` + joining pool: an NLB service targets only the pool,
  so cp-01 never receives LB traffic; joiners are hard-wired to cp-01's IP and a
  recreated cp-01 bootstraps a new cluster.
- Electing the init node at boot: metadata exposes only the instance itself
  (`instance-id`, `local-hostname`, IPs; no pool, index or peers). A scoped
  read-only API key (`get-instance-pool`) on nodes would allow it, at the cost
  of a cloud credential on every node. Not chosen; recorded as the single-pass
  alternative.
- Elastic IP with healthcheck on several instances, HAProxy on the jumphost:
  unverified / single point of failure.

Record in an ADR (`docs/decisions/008-exoscale-module.md`).

## 5. Network and firewall (B2)

- Every node: public IPv4 (NLB members, metadata/Ignition, egress; ADR 008).
  `control_plane_public_ip` and pool `public_ip = false` → precondition error
  explaining why (confirmed by S2).
- `exoscale_private_network` with managed DHCP from `vpc_cidr` (pool members
  cannot have static leases). Cluster traffic on the second NIC (`ens6`).
- `vpc_mtu` default 1500, precondition ≤ 1500. Pod MTU = 1450 via existing
  `pod_veth_mtu`.
- `enable_write_node_ip = true` (two NICs, both with addresses; RKE2 must pick
  the privnet one). `vpc_iface_regex` for canal.
- No `configure-network.sh` needed: S3 showed NetworkManager DHCPs the privnet
  NIC with its default connection and MTU 1500 matches the platform.
- SGs (`modules/rke2-ports`). **The jumphost is the only SSH entry** (user
  requirement, 2026-10-06):
  | SG | Inbound |
  |---|---|
  | jumphost | 22 from `admin_cidrs`; 80 only during the image import |
  | control plane | 6443 from `api_cidrs`, 80/443 from `ingress_cidrs`, 9345 from the control plane SG, healthcheck ports from `public-nlb-healthcheck-sources` |
  | workers / GPU | none |

  Egress unrestricted (no egress rules = allow-all on Exoscale; user decision
  2026-10-06). An egress allow-list is possible later (TCP 80/443, 53, 123/UDP,
  ICMP 3/4) without design changes.

  No node has a 22 rule: SSH goes jumphost → node private IP over the privnet
  (`scripts/ssh.sh` ProxyJump), which SGs do not filter; intra-cluster ports
  need no rules either. NLB traffic reaches the public interface with the
  client source IP (spike A: healthchecks fail without the managed group), so
  `api_cidrs`/`ingress_cidrs` clients can also reach a control plane directly
  on those ports. `admin_cidrs` applies to the jumphost only on Exoscale (its
  common description says "jumphost and nodes": provider note in
  `docs/providers/exoscale.md`). State all this there and in
  `docs/security.md`.
- `egress_ips` output = node public IPs.

## 6. Passes

| Pass | Content | Pins |
|---|---|---|
| 1 "Bootstrap" | jumphost build, template (MD5 via deferred `data.http`), NLB, CP pool size 1 with init config, workers/GPU, `cp_init_ready` gate | `cp_initialized = true` |
| 2 "Scale control plane" | CP pool user_data → join, size → `control_plane_count`, close tcp/80 on the jumphost | — |

- If the template cannot be created in the same apply as the build (MD5 unknown
  at plan fails), split pass 1 into "Build image" + "Bootstrap" (3 passes).
- `control_plane_count = 1`: pass 2 only closes the import port.
- `deploy.sh` defines the passes and the `TF_PLAN_HOOK` replacement check;
  pins go to `pass2.auto.tfvars.json` (vultr/evroc pattern).
- New ADR documents why (NLB targets pools only; one bootstrap node).

## 7. Labels (B3)

**Spike S5 (2026-10-06): accepted.** `elemental-created = "20261005-120000"`
was stored on `exoscale_private_network`, `exoscale_nlb`,
`exoscale_instance_pool` and `exoscale_compute_instance`. The docs rule is not
enforced; keep the convention as is. Options considered had it been rejected:
- prefix the value on Exoscale only (`t20261005-120000`) — breaks "one style",
  needs a `docs/conventions.md#labels` note;
- change the convention everywhere to a non-numeric-first form (user-facing
  change → CHANGELOG, leftover tools parse it?).
Prefer a provider-local formatter in `locals.tf` documented in conventions;
same for `elemental-build` if a build_id starts with a digit.

Resources without `labels` in the provider: `exoscale_template`,
`exoscale_security_group`, `exoscale_anti_affinity_group`, `exoscale_ssh_key`
(the last three are global, not zonal). The leftover tool matches them by name
prefix `<cluster>-` (conventions already allow exact-name matching).

## 8. Availability and quota checks (B4)

Spike S6 answered (2026-10-05, de-fra-1, Compute-only IAM key):

- Signing with bash + `openssl` works (`spike/exoscale/scripts/api-checks.sh`).
  A Compute-only role can read `/v2/quota`.
- **Signed** `GET /v2/instance-type` omits types the account may not use (GPU
  families absent with quota 0); unsigned lists them with `authorized=false`
  for everyone. So the check is "type present in the signed list and its
  `zones` contains the zone".
- `/v2/quota` resources match instance families (`gpu3`, `gpurtx6000pro`,
  `gpua30`, `gpua5000`, `gpu3080ti`, `gpu2`, `gpu`), all 0 by default, plus
  `instance` (20), `network-load-balancer` (5), `elastic-ip` (5), `template`
  (30), `private-network` (32), `snapshot` (30); `cpu`/`memory` -1 (unlimited).
  Whether GPU limits count GPUs or instances: unknown until one is raised.

Design: both checks need signing, so one `scripts/exoscale-api.sh` (openssl
HMAC, `jq`) behind `data "external"`, returning type availability and quota
headroom; preconditions on the private network resource hard-fail the plan
(instances incl. jumphost and pool max size, NLB 1, templates 1 per build, GPU
per family). Document that GPU quota is 0 until support raises it. No `exo`
CLI dependency.
- Anti-affinity group: max 8 members → precondition on `control_plane_count`
  if used (create-only attribute).

## 9. GPU

Families (live API, 2026-10): `gpua30` (ch-gva-2), `gpu2` V100 (at-vie-1),
`gpu3` A40 (de-fra-1), `gpua5000` / `gpu3080ti` (at-vie-2), `gpurtx6000pro`
(ch-dk-2, de-fra-1, hr-zag-1), `gpub300.huge` (ch-gva-2). Worker pools must not
use GPU families (evroc rule). Default `region` = `de-fra-1` (gpu3 +
rtx6000pro). Driver: existing precompiled override; check the GPU operator
validates on A40/RTX 6000 Pro.

## 10. Spike (do first, manual, one account)

Run by the user with a throwaway spike kit (`spike/exoscale/`, not committed;
IDs S0–S6); results recorded below and in ADR 008.

0. **Instance pool `user_data` update in Terraform: in place (no pool
   replacement), applied only to new members; size change in the same apply.**
   **Done (2026-10-06, de-fra-1):** plan shows `update` on `size,user_data`
   only; apply 1m15s; init member kept; both new members joined through the
   NLB, all 3 healthy, round-robin even. `instances` read right after the scale
   call is stale (lists 1 member) until the next refresh: the `nodes` output
   and the init gate must not rely on it in the same apply.
   Also confirmed (S4): member name `<prefix>-<pool id 5>-<random>`; metadata
   `local-hostname` = member name; members inherit pool labels; metadata
   `local-ipv4` is the **public** IP (privnet address only from the NIC);
   the init member keeps being served the init user_data (metadata is per
   member, not per pool).
   **Pool members get the privnet NIC hot-plugged after boot** (race: 1 of 3
   had eth1 before cloud-init, 2 did not). DHCP on the late NIC works.
   Standalone instances with `network_interface` have it at boot.
   Impact: `write-node-ip.sh` counts NICs once and exits on a single NIC, so a
   pool member can come up with RKE2 on the public IP. Needed in
   `elemental-config`: an opt-in mode that always waits (≈300 s) for an IPv4
   in `vpc_cidr` and fails otherwise, and RKE2 ordered after it
   (`Requires=`, not only `Before=`). Spike B checks Elemental's DHCP on the
   hot-plugged NIC (`test_pool_node`).
   Scale-down 3 → 2 removed the oldest member (the init node), as documented.
   Evict (`PUT /v2/instance-pool/{id}:evict`) removed the chosen member,
   size 3 → 2 (2026-10-06 rerun).
   **NLB healthchecks do not come from the pool or the operator**: with 9345
   allowed only from `admin_cidrs` and the pool SG, all members went unhealthy.
   Exoscale documents the managed group `public-nlb-healthcheck-sources`
   (rule `public_security_group = "public-nlb-healthcheck-sources"`).
   SG design: healthcheck ports from that group, 9345 from the control-plane SG
   (joins through the NLB keep the member's source IP), 6443 from `api_cidrs`,
   80/443 from `ingress_cidrs`; nothing else public.
   **Confirmed (2026-10-06):** with 9345 never public (rules: managed
   healthcheck group, pool SG to itself, operator /32s), the init member was
   healthy and both joiners joined through the NLB; 3/3 healthy. Spike A
   complete.
   Private Ubuntu instance never reachable on the privnet (console not
   checked); spike B's private Elemental node covers B2 directly.
1. Register an Elemental raw and a qcow2 as `exoscale_template` (`uefi`) from a
   jumphost HTTP URL: accepted formats, time, MD5 handling.
2. Boot a node with Ignition `exoscale` platform: public instance works;
   `private = true` fails (B2). Gzip+base64 user_data accepted and decoded.
3. Root growth, hostname, eth1 DHCP on the privnet, MTU.
4. Control-plane pool: members inherit pool labels (leftover tool); metadata
   `local-hostname` = member name; which Elemental unit reads `runtime.env`
   (oneshot ordering); NLB healthcheck on 9345 `/ping` and its source
   addresses; joiners through `<nlb_ip>:9345` once the init node is up.
5. Label value starting with a digit on instance/privnet/SG/EIP (B3).
6. **Done** (section 8). `GET /v2/instance-type` fields (authorized flag) and `/v2/quota` signing
   with `openssl`.

## 11. Implementation order

Design is in [ADR 008](../decisions/008-exoscale-module.md). Each step is one
PR from a branch, CI green, merged by squash/rebase. `spike/exoscale/` is
never committed (delete it; the results are in this plan and the ADR).

### PR 0 - plan and ADR (docs only)
- `docs/plans/exoscale.md`, `docs/decisions/008-exoscale-module.md` (Status:
  Proposed), ADR index.

### PR 1 - dropped: no `elemental-config` change needed
`elemental-config` already takes `extra_butane_units`/`extra_butane_files`, so
both node-side pieces ship from `modules/exoscale` into the Exoscale image:
- `node-hostname.service` + script: reads metadata `local-hostname`, sets the
  hostname, writes `config.yaml.d/98-node-name.yaml`; `After=
  network-online.target`, `Before=` and `RequiredBy=` `rke2-server.service`
  `rke2-agent.service` (no RKE2 start with a placeholder name). The pool's
  Ignition entry keeps a placeholder hostname that the service overwrites;
  on standalone nodes the metadata name equals the hostname.
- `wait-privnet.service` + script: waits up to 300 s for an IPv4 inside
  `vpc_cidr` (hot-plugged NIC), `Before=write-node-ip.service` and the RKE2
  units, `RequiredBy=` the RKE2 units.
Other providers' images and `build_hash` cannot change. The stale
`k8s-config-installer.service` in write-node-ip's `Before=` stays a separate
cleanup (it would rebuild every provider's image).

### PR 2 - `modules/exoscale` + `examples/exoscale` (the provider)
(Branch from `main`; numbering kept so PR 3-5 references stay valid.)
Commit order inside the branch, each `terraform validate`/`test` clean:
1. `versions.tf` (`exoscale/exoscale ~> 0.74`), `variables.tf`
   (`exoscale_api_key`, `exoscale_api_secret`, `cp_initialized`,
   `image_import_port_open`), `variables-common.tf` symlink, `locals.tf`
   (coalesce defaults: `region = "de-fra-1"`, `vpc_mtu = 1500`,
   `image_disk_size = "5G"`, labels, naming).
2. `availability.tf` + `scripts/exoscale-api.sh` (openssl signing, `jq`) behind
   `data "external"`: type in signed `/v2/instance-type` and zone; quota
   headroom (instances incl. jumphost and pool max, NLB, templates, GPU per
   family); preconditions on the private network resource. Rejections: more
   than one zone, pool `zone`, `public_ip = false`, `placement`, `bare_metal`,
   `vpc_mtu > 1500`, `image_disk_size` > 1000G, `cluster_name` length for
   `instance_prefix` (30), `control_plane_count` > 8 (anti-affinity).
3. `network.tf` (managed private network from `vpc_cidr`), `firewall.tf`
   (rules from `modules/rke2-ports`; healthcheck ports from
   `public-nlb-healthcheck-sources`; 9345 from the CP SG).
4. `build.tf`/`image.tf`: jumphost (Leap 16.0 template,
   `replace_triggered_by` the serve path), factory hooks (qemu-tools in
   `pre_build`, convert + resize ≥ 10 GiB + md5 in `deliver`), `image_served`
   wait, deferred `data.http` MD5, `exoscale_template` (uefi),
   `terraform_data.build_access`, `build_status.method = "http"`.
5. `control-plane.tf`: `exoscale_instance_pool` (init/join `user_data` by
   `cp_initialized`, size 1 / `control_plane_count`, anti-affinity group,
   `instance_prefix = "<cluster>-cp"`), `terraform_data.cp_init_ready`
   (`scripts/wait-for-cp-init.sh`, 9345 `/ping` via the jumphost).
6. `loadbalancer.tf`: `exoscale_nlb`, services 6443, 9345, 80, 443 with
   healthchecks (9345 `/ping`, ingress per `rke2-ports.lb_ingress_health`).
7. `agent-nodes.tf`: workers/GPU as `exoscale_compute_instance` with static
   privnet leases, per-node Ignition.
8. `outputs.tf` (exact output set; CP members from a refreshed data source,
   not the pool's `instances` in the same apply), README (`make docs`).
9. `tests/*.tftest.hcl` with `mock_provider`: preconditions, init/join switch,
   label set, output set.
10. `examples/exoscale/` (byte-identical `outputs.tf`, `variables.tf`,
    `terraform.tfvars.example`, README) and `deploy.sh`: passes "Bootstrap"
    and "Scale control plane", pin `cp_initialized`, `TF_PLAN_HOOK` failing
    when `exoscale_instance_pool.cp` would be replaced after init,
    `deploy_after_destroy` → leftover command.
11. Repo wiring: `scripts/lib/tf.sh` `TF_JQ_DEFS` (`exoscale_*`),
    `scripts/check-consistency.sh`, `.github/workflows/ci.yml` validate matrix,
    `docs/providers/exoscale.md`, `docs/conventions.md` (pool field table,
    `provider` enum, CP naming exception, unlabelled types),
    `docs/architecture.md`, `README.md` tables, `CLAUDE.md` (provider facts,
    passes, platform id, user_data limit), ADR 008 → Accepted, `CHANGELOG.md`.
- Before merge, user runs e2e (below) and adds required check
  `validate (exoscale)` to ruleset `protect-main` (11 → 12).

### PR 3 - `tools/leftovers/exoscale.sh`
- On `scripts/lib/leftovers.sh` and `scripts/exoscale-api.sh` (no `exo` CLI):
  labelled objects by `elemental-cluster`, unlabelled ones (security groups,
  anti-affinity group, SSH key, templates) by name prefix; test with a fake
  API responder; Makefile `test-scripts`.

### PR 4 - `tools/cost` exoscale
- `internal/provider/exoscale/` (defaults + `TestDefaultsMatchLocals`, expand,
  catalog from `https://portal.exoscale.com/api/pricing/opencompute`, no zone
  dimension), `all/all.go`, golden files, README, docs "Cost estimate".

### PR 5 - remaining docs
- `docs/scaling.md` (CP scale-down: drain, etcd member remove, `:evict`),
  `docs/security.md` (public IP model, SG table), `docs/manual-deploy.md`,
  `docs/e2e-checklist.md`, `tools/multicluster/README.md`,
  `scripts/tests/multicluster_test.sh` loop.

### e2e checks for PR 2 (user runs)
1. `deploy.sh` with `control_plane_count = 3`, one worker pool: both passes
   complete; `kubectl get nodes` shows 3 control planes + workers Ready with
   privnet INTERNAL-IPs and metadata hostnames.
2. NLB: all 4 services healthy; Rancher reachable at the NLB IP sslip.io name;
   9345 not reachable from outside. Entry points: SSH to any node's public IP
   times out; `scripts/ssh.sh <node>` works through the jumphost; a worker's
   public IP answers on no port.
3. Re-run `deploy.sh`: no changes (pins stable, no pool replacement).
4. Evict one CP member: the pool recreates it, it joins through the NLB.
5. `--rebuild`: new template, jumphost replaced, nodes not replaced unless
   intended (`ignore_changes` on user_data/template as in other providers).
6. `deploy.sh --destroy`, then the leftover check prints nothing.
7. GPU pool once quota is granted (separate run).

## 12. Open questions for the maintainer

All answered (2026-10-06):
- Public IP on every node: required (S2) and the platform's expected pattern
  (NLB direct return, no private pools in Terraform, no managed NAT; ADR 008).
- Label convention unchanged (S5); quota checks with `openssl`, no `exo` CLI (S6).
- Single zone: accepted.
- Control plane hostnames `<cluster>-cp-<pool id>-<random>`: accepted as a
  documented naming exception.
- `image_disk_size` default for Exoscale: `5G` (first full e2e deploy confirms
  the full component set fits).

Future work: private worker nodes (`proxmoxve` platform id, NAT instance) once
the VPC is GA and attachable from Terraform.

## Sources

- Provider: https://registry.terraform.io/providers/exoscale/exoscale/latest ,
  https://github.com/exoscale/terraform-provider-exoscale/releases
- NLB limits: https://community.exoscale.com/product/networking/nlb/service-boundaries/limits-and-quotas/index.md
- Instance pools (naming, scale-down order, evict): https://community.exoscale.com/product/compute/instances/how-to/instance-pools/
- Metadata keys: https://pkg.go.dev/github.com/exoscale/egoscale/v3/metadata
- Private instances: https://community.exoscale.com/product/compute/instances/how-to/private-instances/index.md
- Custom templates: https://community.exoscale.com/product/compute/instances/how-to/custom-templates/index.md
- Labels: https://community.exoscale.com/product/compute/instances/how-to/labels/index.md
- Ignition platforms: https://coreos.github.io/ignition/supported-platforms/
- Afterburn: https://github.com/coreos/afterburn/blob/main/docs/platforms.md
- Instance types (unauthenticated): https://api-ch-gva-2.exoscale.com/v2/instance-type
- Pricing: https://portal.exoscale.com/api/pricing/opencompute
