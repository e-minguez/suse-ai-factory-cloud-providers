# Vultr platform notes

Platform behaviour that decides how the Vultr module is built and which plans
work with an elemental image. Elemental produces an image that is EFI-only and
immutable: no kernel sources, no writable root, no post-boot compilation.
Design and variables: [`modules/vultr/README.md`](../../modules/vultr/README.md).
Run it: [`examples/vultr/README.md`](../../examples/vultr/README.md).

## Passes: 2, and why

Diagrams: [architecture](../architecture.md#vultr-two-passes).

`vultr_load_balancer` has no separate backend or firewall-rule resources:
`attached_instances` and the rules are inline fields. The load balancer address
is baked into the image (`api_vip`, `api_host`, Rancher hostname), the nodes boot
from the snapshot that image produces, so a backend list that references the
nodes closes a dependency cycle.

The module takes the backend list as plain variables instead
(`lb_backend_instance_ids`, `lb_supervisor_extra_cidrs`, `agent_cloud_extra_cidrs`,
default `[]`) and `deploy.sh` runs two passes:

1. Create infrastructure: load balancers with no backends, jumphost, image build,
   snapshot import, nodes.
2. Attach load balancer backends: `deploy.sh` reads `provider_details` from pass 1,
   writes `pass2.auto.tfvars.json`, and applies again.

Pass 2 also sets `image_import_port_open = false`. The jumphost tcp/80 rule that
the snapshot import needs is a `vultr_firewall_rule`, and a resource cannot be
created and removed in one apply. Terraform loads `*.auto.tfvars.json` on every
later run, so the values stay pinned; use `./deploy.sh`, not a bare
`terraform apply`, after a node is replaced. The decision and the alternatives are in
[ADR 006](../decisions/006-vultr-two-passes.md).

On a rerun, pass 1 keeps the pinned values, so a cluster without changes plans
nothing and the load balancers keep their backends. It resets them and plans
again when the plan deletes a node or the NAT gateway (stale IDs), or creates
the snapshot (tcp/80 needed) or a load balancer (file left from an earlier
cluster). The backends are then detached until pass 2. A missing or reset
`pass2.auto.tfvars.json` is rebuilt from the `provider_details` output first.

## Images

- The jumphost builds the raw image and serves it over HTTP on port 80 for
  `image_serve_seconds` (3600). Terraform imports it with `vultr_snapshot_from_url`
  (`use_uefi = true`). The snapshot is account-wide, so the image output has one
  key. `terraform destroy` deletes it.
- The import is attempted once. When the fetch fails Vultr deletes the snapshot
  record and the provider reports the 404 on every refresh. Recovery:
  `terraform state rm 'module.ai_factory.vultr_snapshot_from_url.ai_factory[0]'`,
  then `./deploy.sh` (or `./deploy.sh --rebuild` after the serve window closed).
- Vultr does not report UEFI back for a snapshot. A node that boots is the check.
- The jumphost does not hold a Vultr API key. Terraform polls the URL from the
  operator machine first, over the same public path the fetcher uses.
- Python 3 on the jumphost is the HTTP server (`python3 -m http.server`); this is
  an accepted exception to the no-Python-on-instances rule (`CLAUDE.md`).

## Load balancers

- The provider can return from create with `ipv4 = ""` before Vultr assigns the
  address. A create-time script (`modules/vultr/scripts/wait-for-lb-ipv4.sh`) waits, and
  `data.http.lb` reads the address from the API. Terraform defers a data source to
  apply when any managed resource it references has a pending change, and pass 2's
  `attached_instances` update is one: the address, the build id and every node
  would be unknown and replaced. The ids therefore go through
  `terraform_data.lb_ids`, which has no change while the ids are stable, so the
  read stays at plan time on both passes (pass 1 and an LB replacement still defer
  it until the address exists). The data source carries no postcondition, which
  would make the check transitive again; the "address present" check is a
  precondition on `random_id.serve_path`. The wait script is listed in
  [workarounds](../workarounds.md).
- `proxy_protocol` is per load balancer, and a load balancer has one health check.
  The API load balancer (6443, 9345; TCP check on 6443) and the ingress load
  balancer (80/443 with proxy protocol; HTTP check on `/ping`, port 8080) are
  therefore separate. Traefik trusts PROXY headers from `vpc_cidr` and answers
  `/ping` on a hostPort; ports 80 and 443 cannot be health-checked because the
  checker sends no PROXY header.
- 9345 accepts the NAT gateway public addresses and the public `/32`s of
  worker and GPU nodes: control-plane nodes have no public NIC, so their join traffic reaches the
  load balancer through the NAT gateway.
- A `tcp` health check returns an empty `path`; the provider default is `/`, so the
  module ignores changes to that one attribute.
- sslip.io names work for Rancher and the API: `rancher-<ingress-ip>.sslip.io`,
  `rke2-<api-ip>.sslip.io`.

## Labels

Instances and bare metal servers take `tags` as `"key=value"` strings. Every
node carries the managed `elemental-{cluster,managed-by,module,created}`
labels plus `role` (`control_plane`, `worker`, `gpu`), `pool` (`cp` for control
planes) and `build` (`build_id`). The jumphost carries `role=jumphost` and no
`pool` or `build`. `var.tags` is merged in and cannot use the managed prefix. Objects the provider
cannot tag are listed under [Known limitations](#known-limitations).

## Network

- The module uses the original VPC (not VPC 2.0): it is the version wired to
  `vultr_bare_metal_server.vpc_id` and `vultr_instance.vpc_only`. The default
  `vpc_cidr` is `10.20.0.0/20`, `vpc_mtu` 1450 (pod MTU 1400).
- Control-plane nodes are `vpc_only`: one NIC, egress through `vultr_nat_gateway`.
  Vultr grants the registered VPC address to the first DHCP transaction only;
  later leases on that NIC fall back to a CGNAT range. `configure-network.sh`
  therefore leaves that NIC's connection profile alone and sets MTU with
  `ip link`. The node shape is decided by counting physical NICs, because the
  metadata tree reports `ipv4/address` as `dhcp` on `vpc_only` nodes.
- Bare metal nodes have two NICs with default gateways. `write-node-ip.sh` pins the
  RKE2 node IP to the address inside `vpc_cidr` (see `CLAUDE.md`).
- Metadata is served on `169.254.169.254` without authentication and is not
  reachable over a VPC NIC before its DHCP has completed.

## Bare metal

- Current `vbm-*` plans boot in EFI mode. One plan is BIOS-only, and Vultr's iPXE
  documentation describes bare metal as Legacy PCBIOS. Firmware settings belong to
  the physical host and are not reset between tenants. If a host reports `active`
  and never answers, check the boot mode from the console
  (`vultr-cli bare-metal vnc <server-id>`).
- `uefi` exists only on `POST /snapshots/create-from-url`; `POST /bare-metals` has
  no boot-mode parameter.
- `POST /bare-metals` has no VPC-only or public-IPv4 option. The VPC is attached
  after create, so every bare metal node has a public address.
- `firewall_group_id` exists on instances and not on bare metal (API, govultr,
  `vultr-cli`, Terraform provider 2.32). See Security below.
- A NIC can report `NO-CARRIER` on the host side while the API holds the VPC
  attachment; nothing in the image changes that. Check
  `/sys/class/net/<if>/carrier` first.

## Cloud GPU

The `vcg-*` prefix covers two products, and neither the id nor the API `type`
field alone identifies which one a plan is.

- vGPU plans cannot run on this image. The guest driver is installed with
  `/opt/nvidia/install.sh`, rebuilt by DKMS on kernel change and licensed by
  `nvidia-gridd.service`. NVIDIA documents that precompiled driver containers do
  not support vGPU.
- Passthrough plans can, through the precompiled driver path. Two groups:
  - `type: vdm` (`disk_type: DEDICATEDMETAL`): `vcg-a100-*`, `vcg-h100-*`,
    `vcg-b200-*`, `vcg-mi3*`, plus `vcg-a16-6c-*`, `vcg-a16-96c-*`,
    `vcg-a40-24c-*` and `vcg-a40-96c-*`. Tested: `vcg-a40-24c-120g-48vram`
    (blr, 2026-09-30), where the 615 driver loaded and `nvidia-smi -q` reported
    a full `NVIDIA A40` (46068MiB) with `Virtualization Mode: Pass-Through`.
  - The L40S plans (`vcg-l40s-16c/32c/64c-*`, 1/2/4 whole GPUs), although they
    report `type: vcg` / `disk_type: CLOUDGPU`. The
    [GPU variants page](https://docs.vultr.com/products/compute/instances/cloud-gpu/explore-gpu-variants)
    lists the L40S implementation as passthrough (and A16, A40, A100 as vGPU;
    the page is per GPU model and does not cover the `vdm` plans). The L40S is
    also the GPU the precompiled driver path has run on elsewhere.
- The remaining `vcg` plans (the other a16/a40 sizes) are fractional vGPU.
- The h100, b200 and mi3xx plans have `deploy_ondemand: false` (preemptible
  only, which the module does not request); the a16, a40 and a100 `vdm` plans
  and the L40S plans are on-demand. Stock is intermittent.
- `GET /v2/plans` omits `gpu_type`, `gpu_count` and `gpu_vram_gb` on every `vdm`
  plan (the 8x B200 plan shows no GPU), while `vcg` plans carry them, so filters
  on those fields miss most passthrough plans. Its `locations` is also
  inconsistent: `[]` from `vultr-cli` where the authenticated API said `["sea"]`,
  and `?type=all` has omitted a `vdm` plan that plain `/v2/plans` returned.
  Check stock with the availability endpoint
  ([Plan availability](#plan-availability)).
- `kind = "vm"` pools take a firewall group, and with the default
  `public_ip = false` have no public NIC.

## GPU driver

The release manifest points at `registry.suse.com/third-party/nvidia`, which
publishes SLES 16.0 driver builds. A 16.0 module does not load on the 16.1 kernel,
so `gpu_driver_repository` and `gpu_driver_version` default to an experimental
build. Removal condition: [workarounds](../workarounds.md). On Vultr, the driver has
loaded on one plan (`vcg-a40-24c-120g-48vram`, see [Cloud GPU](#cloud-gpu)); bare
metal GPU plans have not been run.

## Bare metal GPU plans

`GET /v2/plans-metal` lists the plans. Prices change; run `make cost PROVIDER=vultr TFVARS=...` ([tools/cost](../../tools/cost/README.md)) for a current estimate of a configuration.

All use passthrough. The GH200 is ARM and elemental3 customizes x86_64 images
only. `gpu_pools` defaults to `{}`.

## Worker pools

`worker_pools` takes the same fields and the same limits as `gpu_pools` (`zone`,
`disk_size_gb` and `placement` null, `kind` matching the `vbm-*` prefix) and
defaults to `{}`. Worker and GPU nodes share one resource path, firewall group,
stock check and `agent_node_cidrs` value; only `nodes[*].role` differs (`worker` or
`gpu`). Pool keys are unique across both maps.

## Plan availability

`available_plans` is live stock, not the set of plans a region offers. Send the
`Authorization` header: without it the endpoint answers HTTP 200 with an empty
list.

The module queries it once at plan time, without `?type=`
(`data.http.plan_availability`), for the control plane, the jumphost and every worker or
GPU pool that has something to create; a missing plan fails the plan and names the
pool. The untyped answer is the union of every family (`vc2`, `vx1`, `vbm`,
`vcg`, `vdm`; confirmed against blr's `vcg-a40-24c` and sea's `vcg-b200`). A typed
query needs the plan's `type` field, which the id prefix does not give, so there
is no `plan_type` input. Stock can still drain before apply.

Skipped pools:

- `count = 0`: a pool can be parked while its plan is out of stock.
- Pools whose nodes all exist. Stock is often one unit, held by the cluster's own
  node, so re-checking it would fail every later plan of a healthy cluster.
  Existence comes from the API (`data.http.agent_existing`, which covers worker and GPU pools, `GET /v2/instances` and
  `/v2/bare-metals`, one page of 500), matching label (the hostname), plan and
  region. The node resources depend on the check, so reading their state would be
  a cycle, and the API answer also holds after a state loss. A node beyond the
  first page looks missing, which runs the check. Adding a node or changing a
  pool's plan re-enables the check for that pool.

Manual check for one region:

```bash
curl -s -H "Authorization: Bearer $VULTR_API_KEY" \
  "https://api.vultr.com/v2/regions/$REGION/availability" \
  | jq -r '.available_plans[]' | grep -E '^(vbm|vcg)-'
```

### Passthrough stock across regions

`tools/vultr/passthrough-stock.sh` lists GPU passthrough plans in stock in every
region (`vdm` and L40S cloud plans, and GPU bare metal) and flags where the plan catalogue
disagrees with that stock. Needs `curl` and `jq`; region ids as arguments limit
the sweep. It retries the API's rate limiting (429, 5xx) instead of reading a
throttled reply as no stock.

```bash
VULTR_API_KEY=... tools/vultr/passthrough-stock.sh [region ...]
```

On 2026-09-30 it found two across 33 regions: `vcg-a40-24c-120g-48vram` in blr
(on-demand) and `vcg-b200-248c-2826g-1536vram` in sea (preemptible only).

## Security

Vultr Firewall does not apply to bare metal servers: `firewall_group_id` is absent
from `POST /bare-metals`, `PATCH /bare-metals/{id}`, the `bare_metal` response
object and `vultr_bare_metal_server`. Vultr documents firewall groups for Cloud
Compute, Cloud GPU and VX1 instances only.

- Every `gpu_pools` or `worker_pools` entry with `kind = "bare_metal"` is reachable on its public
  IPv4/IPv6 address on every port until a host-level filter runs on the node. The
  image does not implement one yet; treat those nodes as exposed
  (`nmap -Pn <node-ip>`). A host policy would default-deny inbound and allow
  established traffic, loopback, tcp/22 and tcp/6443.
- `kind = "vm"` pools get a firewall group (RKE2 ports from the VPC CIDR, SSH from
  `admin_cidrs`) or no public NIC at all.
- The API load balancer admits 6443 from `api_cidrs` (default `0.0.0.0/0`) and
  9345 from the NAT gateway and the public agent addresses only.
- Control-plane nodes are `vpc_only`. The jumphost accepts SSH from `admin_cidrs` and tcp/80 during an import. See also
  [security](../security.md).

## Cost estimate

`make cost PROVIDER=vultr TFVARS=...` estimates the cost from tfvars
([tools/cost](../../tools/cost/README.md)). Plan prices come from the public
plans API (no key, cached); load balancer, NAT gateway and snapshot rates are
fixed values in the tool because the API does not list them. It prices
instances, bare metal and cloud GPU plans, the load balancers, the NAT gateway
and the snapshot; monthly-invoiced plans are capped at the monthly rate.
Bandwidth overage is not included. The result is an estimate, not a quote.


## Known limitations

- Untagged objects: `vultr_load_balancer` (label only), `vultr_vpc`,
  `vultr_firewall_group` and `vultr_snapshot_from_url` (description only) and
  `vultr_firewall_rule` have no tags in the provider, so they carry no
  `elemental-*` labels. Load balancers, VPC and firewall groups carry
  the cluster name in their label or description.
- The snapshot description is computed-only in `vultr_snapshot_from_url`.
  `wait-for-snapshot.sh` sets it to `<cluster_name>-<build_id>` with
  `PUT /v2/snapshots/{id}` once the import is `complete`; a failed PUT fails the
  provisioner and taints the snapshot. The provider only reads the field, so
  there is no plan drift. The PUT retries on HTTP 5xx and connection errors
  (5 attempts). The snapshot carries the description only after the import
  completes.
- Firewall rules have no identity of their own: they are deleted with their
  group and are not listed.
- `tools/leftovers/vultr.sh <cluster_name>` (needs `VULTR_API_KEY` exported)
  finds tagged instances, bare metal servers and NAT gateways by the
  `elemental-cluster` tag, and the untagged objects by exact name
  (`<cluster_name>` plus `-api-lb`, `-ingress-lb`, `-vpc`, `-jumphost`,
  `-control-plane`, `-agent-cloud`, and `-<build_id>` for snapshots). A cluster
  named `prod` does not match `prod-2-*`.
- `vultr_nat_gateway` takes a single tag string:
  `elemental-cluster=<cluster_name>`.

## Sources

- Vultr, [iPXE Boot Feature](https://docs.vultr.com/ipxe-boot-feature).
- Vultr, [Explore GPU Variants](https://docs.vultr.com/products/compute/instances/cloud-gpu/explore-gpu-variants).
- Vultr, [Managing vGPU on Vultr Cloud GPU Instances](https://docs.vultr.com/how-to-manage-vgpu-on-vultr-cloud-gpu-instances).
- NVIDIA, [Precompiled Driver Containers](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/precompiled-drivers.html).
- SUSE, [`third-party/nvidia/driver` images](https://registry.suse.com/repositories/third-party-nvidia-driver-sles16).
- Vultr API: `GET /v2/regions/{region}/availability?type=vcg|vdm|vbm`,
  `GET /v2/plans?type=all`, `GET /v2/plans-metal`.
