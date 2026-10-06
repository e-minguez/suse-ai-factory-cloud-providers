# 008 - exoscale module design

## Status
Proposed. Based on spike tests in de-fra-1 on 2026-10-05/06 with provider
`exoscale/exoscale` v0.74.2; not implemented yet
([plan](../plans/exoscale.md)).

## Context
Platform behaviour that shapes the module, each confirmed by a spike test
unless marked as documented:

- An `exoscale_nlb_service` targets one instance pool, never individual
  instances (documented). Every pool member gets the same `user_data`, while
  `elemental-config` renders per-node Ignition (hostname, role, init flag).
- Pool member names are `<instance_prefix>-<5 chars of pool ID>-<random>`,
  not ordinal. Metadata exposes only the instance itself (`local-hostname`,
  `instance-id`, IPs); `local-ipv4` is the public address.
- Changing a pool's `user_data` and `size` is an in-place update: the provider
  sends the update, then the scale call. Existing members keep being served
  their original `user_data`; new members get the new one. Scale-down removes
  the oldest members first; `:evict` removes chosen members.
- Instances with `private = true` have no 169.254.169.254 metadata service.
  Ignition's `exoscale` platform reads only that endpoint: a private Elemental
  node stops in emergency mode ("Failed to start Ignition (fetch)").
- Pool members get their private network NIC attached after boot, sometimes
  after early userspace has started. NetworkManager configures it by DHCP.
- NLB healthchecks come from addresses outside the pool and the operator
  networks; Exoscale publishes them as the managed security group
  `public-nlb-healthcheck-sources`. The NLB keeps the client source address.
- Templates accept qcow2 only, virtual size 10–1000 GB, MD5 checksum, one
  template per zone. Registration of an 887 MB qcow2 took 16 s.
- `exoscale_compute_instance.user_data` updates in place.
- Signed `GET /v2/instance-type` omits types the organization may not use;
  `/v2/quota` lists limits per GPU family (0 by default). Both need
  EXO2-HMAC-SHA256 signed requests; there is no Terraform data source.
- Label values starting with a digit are accepted, although the documentation
  says otherwise. Security groups, anti-affinity groups, SSH keys and templates
  have no labels.

## Decision
- **Control planes in one `exoscale_instance_pool`**, target of the API
  (6443, 9345) and ingress (80, 443) NLB services. Workers and GPU nodes stay
  standalone `exoscale_compute_instance` resources with per-node Ignition.
- **Two passes for the control plane**: pass 1 creates the pool with size 1 and
  the init configuration and waits until its supervisor answers; `deploy.sh`
  then pins `cp_initialized = true`. Pass 2 switches the pool `user_data` to the
  join configuration (`server: https://<nlb>:9345`) and scales to
  `control_plane_count`. Only the init configuration can bootstrap a cluster,
  and it is only rendered while the pool has one member. A plan check fails if
  the control plane pool would be replaced after initialization.
- **Hostname from metadata** for pool members: a oneshot before
  `rke2-server`/`rke2-agent` reads `local-hostname`, sets the hostname and
  writes the RKE2 `node-name` drop-in. Control plane hostnames are
  `<cluster>-cp-<pool id>-<random>`, a documented exception to the naming
  convention.
- **Public IPv4 on every node, the jumphost as the only SSH entry.** Security
  groups are the only ingress filter and do not apply to the private network:
  - jumphost: 22 from `admin_cidrs`;
  - all nodes: no 22 rule; SSH goes through the jumphost to the node's private
    address (`scripts/ssh.sh` ProxyJump);
  - workers and GPU nodes: no inbound rule at all (public IP used for egress
    and the metadata service only);
  - control planes: 6443 from `api_cidrs`, 80/443 from `ingress_cidrs`, 9345
    from the control plane security group, healthcheck ports from
    `public-nlb-healthcheck-sources`. The NLB delivers to the public interface
    with the client address, so these clients can also reach a control plane
    directly on the same ports;
  - egress unrestricted: no egress rules, which Exoscale security groups treat
    as allow-all. An egress allow-list can be added later without changing the
    design.

  Public addresses are kept because the platform expects them and the
  alternatives need extra VMs (NAT, load balancer edge): instances get a public
  IPv4 by default, SKS nodepools only accept `inet4`/`dual`, the NLB returns
  traffic directly from the members' public interface and reports their health
  by public IP, `exoscale_instance_pool` has no private option, and there is no
  managed NAT gateway.
- **Single zone**: private networks and pools cannot span zones.
- **Image**: the jumphost builds a 5G raw image (Exoscale default for
  `image_disk_size`), converts it to qcow2, grows the virtual size to 10 GiB
  and serves it over HTTP;
  `exoscale_template` reads the MD5 at apply time through a deferred
  `data.http`. The jumphost is replaced on every new build.
- **Plan-time checks** through a signing script (bash, `openssl`, `jq`) behind
  `data "external"`, with preconditions for instance type availability and
  quota headroom.

Alternatives considered:
- A standalone init node plus a joining pool: the NLB cannot target the init
  node, and a recreated init node would bootstrap a new cluster.
- Electing the init node at boot: metadata has no peer information; reading
  the pool through the API would put a cloud credential on every node.
- One Elastic IP with healthchecks on several instances, or a load balancer on
  the jumphost: unverified, or a single point of failure.
- Nodes without public IPv4: NLB members need a public interface, so private
  control planes need an HAProxy edge pool in front of them; private nodes
  need a NAT VM for egress and `ignition.platform.id = proxmoxve` (private
  instances get a NoCloud `cidata` drive instead of the metadata service).
  Rejected: no extra VMs beyond the jumphost; the SSH-only-through-the-jumphost
  goal is met with security groups. Revisit when the VPC is GA and the provider
  can attach instances to VPC subnets.

## Consequences
- The Exoscale image carries two extra units through `elemental-config`'s
  `extra_butane_units`/`extra_butane_files`: one sets the hostname and RKE2
  `node-name` from metadata, one waits for the private network address before
  `write-node-ip` runs. RKE2 requires both. `elemental-config` itself is
  unchanged.
- Scaling the control plane down needs a manual etcd member removal; the pool
  removes the oldest member first.
- Terraform's `instances` attribute is read right after the scale call and can
  list fewer members until the next refresh; outputs and gates must not rely
  on it within the same apply.
- The leftover tool matches unlabelled objects by name prefix.
- GPU instances need a quota increase through support before the first deploy.
- Not covered by the spike tests: GPU nodes, the full component set in a 5G
  image (first e2e deploy confirms it), multiple control plane members running
  RKE2.
