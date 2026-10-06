# Exoscale platform notes

Platform behaviour that decides how the Exoscale module is built. Design and
variables: [`modules/exoscale/README.md`](../../modules/exoscale/README.md).
Run it: [`examples/exoscale/README.md`](../../examples/exoscale/README.md).
Decision record: [ADR 008](../decisions/008-exoscale-module.md). The behaviour
below was confirmed by spike tests in de-fra-1 (2026-10, provider v0.74.2)
unless marked as documented only.

## Limitations

Read these before choosing this provider:

- **Every node has a public IPv4**: control planes, workers, GPU nodes and the
  jumphost. The network load balancer returns traffic directly from its
  members' public interface, Ignition reads its configuration from the
  metadata service (instances without a public IP do not get one), and egress
  uses it: Exoscale has no managed NAT gateway, and its VPC is beta and cannot
  be attached from Terraform. `control_plane_public_ip` and each pool's
  `public_ip` must be `true`: the example root defaults both to `true`, and
  the module rejects `false` instead of ignoring it.
- **Inbound traffic is filtered by security groups only.** Worker and GPU nodes
  accept nothing from outside; control planes accept the load balancer ports
  (6443 from `api_cidrs`, 80/443 from `ingress_cidrs`, healthchecks, joins);
  the jumphost is the only SSH entry. Clients admitted to 6443 or 80/443 can
  also reach a control plane directly on those ports.
- **No fixed egress address**: each node egresses from its own public IP
  (`egress_ips` lists them); there is no NAT address to allow-list.
- **Single zone**: private networks, instance pools and templates are
  zone-scoped.
- **Control plane names** are `<cluster_name>-cp-<pool id>-<random>`, set by
  the instance pool, not `-cp-NN`.
- No cost estimate (`tools/cost`) yet.

To revisit when the Exoscale VPC is generally available and the Terraform
provider can attach instances to VPC subnets ([ADR 008](../decisions/008-exoscale-module.md)).

## Passes: 2, and why

Diagrams: [architecture](../architecture.md#exoscale-two-passes).

An `exoscale_nlb_service` targets one instance pool, never individual
instances (documented), and every member of a pool gets the same `user_data`.
The control planes therefore share one Ignition entry, and only one of them
may initialize the cluster. Pool members are named
`<instance_prefix>-<5 characters of the pool ID>-<random>`, and metadata only
describes the instance itself, so a member cannot tell at boot whether it is
the first one.

`deploy.sh` runs two passes:

1. Bootstrap control plane: the pool with size 1 and the init configuration
   (`IS_INIT_NODE=true`), plus everything else. The pass ends when the
   Kubernetes API answers through the NLB.
2. Scale control plane: `cp_initialized = true` switches the pool to the join
   configuration and scales it to `control_plane_count`. Joining members reach
   the first one through the NLB on 9345.

A pool `user_data` and `size` change is one in-place update: the provider sends
the update, then the scale call. Existing members keep being served their
original `user_data`; new members get the new one. Ignition runs on first boot
only, so the first member is not affected.

`deploy.sh` takes `cp_initialized` from state (the pool exists), not from its
pin file, and aborts when a plan would create or replace the pool of an
initialized cluster. Pass 2 also closes the jumphost's tcp/80 rule; a later
rebuild reopens it for the import and closes it again.

## Images

- Templates are qcow2 only (a raw is rejected: "The magic QCOW2 number should
  be 1363560955"), with a virtual size of 10 to 1000 GiB and an MD5 checksum,
  registered per zone. The jumphost converts the raw with `qemu-img convert`,
  grows the virtual size to 10 GiB when smaller (metadata only: the file keeps
  the used blocks) and serves the file and its `.md5` on port 80.
- `exoscale_template` needs the checksum at create time. `data.http.image_md5`
  reads it with `depends_on` on the build wait, so the read happens during the
  apply that builds; afterwards the template ignores the checksum.
- Registration of an 887 MB qcow2 took 16 s.
- `exoscale_compute_instance.user_data` updates in place, so a new build
  replaces the jumphost through `replace_triggered_by` instead of leaving
  cloud-init unrun.
- `qemu-img` ships in package `qemu-tools`; it is installed in the factory's
  `pre_build` hook because `extra_packages` needs package name = command name.
- Python 3 on the jumphost is the HTTP server (`python3 -m http.server`), the
  same accepted exception as on vultr (`CLAUDE.md`).
- The public template IDs change when Exoscale updates a template;
  `jumphost_image` takes a name (looked up per plan) or a pinned ID.

## Ignition and metadata

- `ignition.platform.id=exoscale` reads the config from
  `http://169.254.169.254/1.0/user-data`. The API takes at most 32768 base64
  characters of `user_data` (about 24 KiB of payload); the per-node files are
  well below 1 KiB.
- Instances created with `private = true` have no metadata service; they get a
  NoCloud drive labelled `cidata` instead (documented), which this platform id
  does not read. A private Elemental node stops in emergency mode ("Failed to
  start Ignition (fetch)"). Every node therefore has a public IPv4.
- Metadata `local-hostname` is the instance name; `local-ipv4` is the public
  address (the private address only shows on the NIC).
- Afterburn sets no hostname on this platform: standalone nodes take it from
  Ignition, pool members from `node-hostname.service`.

## Network

- One managed private network (L2, zone-local, DHCP, MTU 1500, no jumbo
  frames) carries all cluster traffic. Security groups do not apply to traffic
  inside it (documented).
- NICs are `ens3` (public) and `ens6` (private network). NetworkManager's
  default connection runs DHCP on the private NIC.
- Instance pools attach the private NIC after boot, sometimes after early
  userspace: in one test 2 of 3 Ubuntu members had no `eth1` when cloud-init
  ran. `wait-privnet.service` makes RKE2 wait for the address inside
  `vpc_cidr`. Standalone instances with a `network_interface` have it at boot.
- Terraform exposes no private address for pool members. The module reads the
  private network's `leases` and the pool's current members through the API
  (`data.external.cp_members`); Terraform's own `instances` attribute lists
  fewer members right after a scale call until the next refresh.
- The jumphost has a static lease (`vpc_cidr` host 5) below the DHCP range;
  everything else gets a dynamic lease.
- No managed NAT gateway exists, and the VPC product is beta and cannot be
  attached from Terraform yet; egress uses each node's public IP.

## Load balancer

- One NLB carries 6443 and 9345 (TCP checks) and the ingress listeners 80/443
  (Traefik: HTTP `/ping` on 8080). The NLB address is in the image (`apiVIP`,
  `api_host`, Rancher hostname); `rancher_hostname` and `api_host` default to
  `sslip.io` names on it.
- The NLB keeps the client address and returns traffic directly from the
  member's public interface (documented), so members need a public IPv4 and
  the control plane security group admits the clients themselves.
- Healthchecks come from neither the pool nor the operator: with 9345 limited
  to the operator's IPs and the pool's own security group, every member went
  unhealthy. Exoscale publishes the sources as the managed security group
  `public-nlb-healthcheck-sources`.
- Traefik keeps its PROXY protocol trust for `vpc_cidr`; NLB clients connect
  from their own addresses without a PROXY header.

## Labels

- Label values starting with a digit (`elemental-created = 20261005-120000`)
  are accepted on instances, pools, private networks and NLBs, although the
  documentation says values must start with a letter.
- Pool members inherit the pool's labels.
- `exoscale_security_group`, `exoscale_anti_affinity_group` and
  `exoscale_template` have no labels; the leftover check matches them by name.

## GPUs

- GPU families per zone (2026-10): `gpu3` (A40) de-fra-1; `gpurtx6000pro`
  ch-dk-2, de-fra-1, hr-zag-1; `gpua30` and `gpub300` ch-gva-2; `gpua5000` and
  `gpu3080ti` at-vie-2; `gpu2` (V100) at-vie-1.
- Each family has its own quota, 0 by default; Exoscale support raises it.
  Whether the limit counts GPUs or instances is not documented; the plan-time
  check counts GPUs, which is the stricter reading.
- GPU and large types also need activation for the organization: the signed
  instance type list omits types the organization may not use.

## Quota and availability

`data.external.api_check` runs `modules/exoscale/scripts/exoscale-api.sh`, which
signs requests (EXO2-HMAC-SHA256 with `openssl`) because no Terraform data
source covers instance types or quotas, and the unsigned type list reports
GPU types as unavailable for everyone. `terraform_data.api_check` fails the plan
on:

- a type not offered in the zone or not available to the organization;
- a GPU pool on a type without GPUs, or a worker pool on a GPU type;
- the `instance`, `network-load-balancer` or per-GPU-family quota without
  room for what the next apply adds. Resources this cluster already holds
  (by `elemental-cluster` label) are counted, so a re-plan does not fail on its
  own nodes. A limit of -1 is unlimited.

Capacity can still run out between plan and apply.

## Security

| Security group | Inbound |
|---|---|
| jumphost | 22 from `admin_cidrs`; 80 from anywhere while `image_import_port_open` |
| control plane | 6443 from `api_cidrs`; 80/443 from `ingress_cidrs`; 6443/9345 from the control plane and agent groups (joins through the NLB); healthcheck ports from `public-nlb-healthcheck-sources` |
| agent | none |

- The jumphost is the only SSH entry; `admin_cidrs` applies to it only on
  this provider. SSH to nodes goes through it to their private address.
- Clients admitted by `api_cidrs` or `ingress_cidrs` can also reach a control
  plane directly on the same ports, because the NLB delivers to the public
  interface with the client address.
- No egress rules: Exoscale allows all egress until the first egress rule.
- The API key and secret are inputs of the external data sources and end up
  in state, as other credentials do ([ADR 005](../decisions/005-state-secrets.md)).

## Cost estimate

Not covered by `tools/cost` yet. Exoscale publishes prices as JSON at
`https://portal.exoscale.com/api/pricing/opencompute` (hourly, CHF/EUR/USD, no
zone dimension).

## Leftover check

`tools/leftovers/exoscale.sh <cluster_name> [--region <zone>]` (needs
`EXOSCALE_API_KEY`, `EXOSCALE_API_SECRET`, `curl`, `jq`, `openssl`) lists, read
only, the instances (pool members included), the instance pool, the NLB and the
private network by `elemental-cluster` label, and the security groups, the
anti-affinity group and the templates by name. Exit 0 means nothing is left.

## Operational limits

In addition to [Limitations](#limitations):

- Scaling the control plane down removes the oldest member first and leaves
  its etcd member behind (`docs/scaling.md`).
- A rebuild updates the pool's template in place: existing control plane
  members keep the old image until they are replaced one at a time.
- At most 8 control planes (one anti-affinity group); `cluster_name` at most
  27 characters (pool `instance_prefix` limit of 30).

## Sources

- Terraform provider: https://registry.terraform.io/providers/exoscale/exoscale/latest
- NLB: https://community.exoscale.com/product/networking/nlb/overview/ and
  https://community.exoscale.com/product/networking/nlb/service-boundaries/limits-and-quotas/
- Private instances: https://community.exoscale.com/product/compute/instances/how-to/private-instances/
- Instance pools: https://community.exoscale.com/product/compute/instances/how-to/instance-pools/
- Custom templates: https://community.exoscale.com/product/compute/instances/how-to/custom-templates/
- API request signature: https://openapi-v2.exoscale.com/topic/topic-api-request-signature
- Ignition platforms: https://coreos.github.io/ignition/supported-platforms/
- Metadata keys: https://pkg.go.dev/github.com/exoscale/egoscale/v3/metadata
