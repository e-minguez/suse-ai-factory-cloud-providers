# 012 - exoscale public network mode

## Status
Accepted. Amends the network design of [ADR 008](008-exoscale-module.md);
plan: `docs/plans/exoscale-public-network.md`. End-to-end checks pending.

## Context
- Exoscale no longer enables `create-private-network` for organizations that
  do not already use private networks; the API answers `Forbidden: Operation
  'create-private-network' not enabled`, whatever the IAM role. According to
  Exoscale support, classic private networks stop working on 2027-05-03.
- The replacement is the VPC. `exoscale_instance_pool` only takes `network_ids`
  (classic private networks), so pools cannot join a VPC, and an
  `exoscale_nlb_service` targets instance pools only (ADR 008). Open provider
  PR 639 adds `label_selector` backends to the NLB service; it is not released.
- Every node already has a public IPv4 (ADR 008): the NLB returns traffic from
  it, and joins through the NLB already arrive from the nodes' public
  addresses and are admitted by security-group rules.
- Exoscale's price list states that traffic between instances is free; whether
  this covers public addresses is not stated.

## Decision
- **`network_mode`** in `modules/exoscale`: `"public"` (default) or
  `"private_network"` (today's design). A later `"vpc"` mode fits the same
  variable. `public` is a temporary mode, kept until Exoscale VPC works with
  instance pools and the NLB.
- **Public mode**: no private network, no extra NICs, pools with empty
  `network_ids`. Nodes talk over their public IPv4; RKE2 picks that address
  (single NIC).
- **Security groups reference security groups, never CIDRs**, for every
  intra-cluster port: etcd between control planes; kubelet, NodePort range and
  VXLAN (8472/udp) between all nodes; tcp/22 from the jumphost group. API and join
  ports keep their existing rules.
- **canal keeps its default VXLAN backend**: no backend setting, pod
  MTU 1450 as in `private_network` mode. Etcd is 2379-2381 as in
  `modules/rke2-ports`.
- **Outputs**: nodes' and jumphost `private_ip` are null (`scripts/ssh.sh`
  reaches nodes on their public IP through the jumphost, flagged by
  `provider_details.ssh_via_jumphost`), `network` is `{ vpc_cidr = null, subnet_cidrs = [] }`,
  `provider_details.private_network_id` is null.
- **Breaking change**: switching an existing cluster from the previous
  behaviour to the new default `public` replaces the control-plane pool and
  the nodes, which breaks an initialized cluster (ADR 008). Set
  `network_mode = "private_network"` before upgrading to keep a standing
  cluster; the moved block maps the network to
  `exoscale_private_network.this[0]`.

## Consequences
- Security depends on the security groups alone, because the RKE2 ports are on
  public addresses. Pod overlay traffic (VXLAN) between nodes crosses public
  IPs unencrypted, only between nodes admitted by the SG-to-SG rules; RKE2
  control traffic (etcd, kubelet, API) is TLS-protected. No WireGuard, so FIPS
  is unaffected.
- Pod traffic to another node's IP (hostNetwork or hostPort listeners, e.g.
  observability and security DaemonSets) only reaches ports the SG rules list.
  Checked in e2e.
- The billing of traffic over public IPs between instances is to be verified
  with an end-to-end run or with Exoscale.
- `private_network` mode cannot be tested in organizations without private
  networks, and is removed after 2027-05-03.
- Rejected: canal's WireGuard backend. The mode is temporary, so the default
  backend stays (no per-node backend setting, no FIPS question).
- Planned, not implemented: control planes as standalone instances behind the
  NLB with `label_selector` once PR 639 is released (removes the two-pass
  bootstrap of ADR 008, the member lookup and the hostname-from-metadata unit),
  then `network_mode = "vpc"`. A new ADR will supersede ADR 008 then. Public
  mode is listed in `docs/workarounds.md` and goes once pools or the NLB
  support VPC.
