# Oracle Cloud (OCI) platform notes

Platform behaviour that decides how the OCI module is built. Run it:
[`examples/oci/README.md`](../../examples/oci/README.md). Decision record:
[ADR 012](../decisions/012-oci-module.md). First end-to-end run: 2026-11-16 in
eu-frankfurt-1 (staged: image, one control plane, A10 pool, three control
planes, rebuild, destroy). Items still open are listed at the end.

## Limitations

- Nodes have no public IP: `control_plane_public_ip` and a pool `public_ip`
  must be false, `placement` null, `kind` `"vm"`; each fails the plan.
- VM shapes only: bare metal shapes (all BM GPU shapes) cannot boot an imported
  image.
- Imported images do not support Secure Boot.
- One region per cluster; zones are availability domains, lowercase (`ad-1`).

## Passes: 1, and why

The NLB and its reserved public IP exist before the image, the image before the
instances, and NLB backends are separate resources added after the instances.
No cycle, so one pass ([ADR 012](../decisions/012-oci-module.md)).

## Images

1. The jumphost (Oracle Linux 9 platform image, `dnf`) builds the raw image with
   podman, converts it to qcow2 with `qemu-img` (package `qemu-img`,
   `ol9_appstream`) and uploads it with `curl -T` to a write-only
   pre-authenticated request, then writes a `done` marker the same way, from a
   file: curl sends stdin chunked, and Object Storage answers chunked PUTs with
   HTTP 501.
2. Terraform polls the marker with a read-only PAR (`curl -sfI`).
3. `oci_core_image` imports the qcow2 (`objectStorageTuple`, `QCOW2`,
   PARAVIRTUALIZED), then a capability schema sets `Compute.Firmware = UEFI_64`.
4. The objects in the bucket are overwritten with a one-line object, so destroy
   deletes them and the bucket.

The image is rebuilt only when `build_hash` changes. `image_id` skips the chain.
Minimum virtual size: the import documentation states none; the factory does
not resize, and an 8 GiB qcow2 imports and boots (verified). Single PUT through
a PAR up to 50 GiB (887 MiB in 8 s from the jumphost). HEAD on a read PAR works
for polling, and fails until the object exists (verified).

Expired PARs: the Object Storage documentation says an expired PAR stops
working and that deleting one revokes access, but not whether expired PARs stay
listed or readable. Open (`oci os preauth-request list` after 24 hours). The jumphost sets `ignore_changes = [metadata]`: its user_data
holds the write PAR URLs and is immutable on OCI, so a recreated PAR must not
replace it; a new build still replaces it through `build_trigger`. If expired
PARs disappear, the plan after 24 hours proposes to recreate them (new
`access_uri`, no effect on the jumphost); applying that is harmless once the
image exists.

## Ignition and metadata

- `ignition.platform.id=oraclecloud` (Ignition 2.22 or later; the image ships
  2.26). It reads `user_data` from `/opc/v2/instance/metadata/user_data`,
  base64, no gzip: per-file compression (`compress_node_files`) is used.
- Metadata (user_data in base64 plus ssh keys) is limited to 32000 bytes; the
  plan checks the jumphost's and `elemental-config` limits the nodes' Ignition
  (22000 bytes).
- Single VNIC per node: `write-node-ip.sh` is not needed.

## Network

- VCN (`vpc_cidr`, default `10.20.0.0/20`): public subnet (low half: jumphost,
  NLB) and private subnet (high half: nodes), internet gateway, NAT gateway,
  one route table each. Subnets are regional.
- NSGs `jumphost`, `nlb`, `control-plane`, `agent` carry every inbound rule;
  the VCN default security list allows egress and inbound ICMP "fragmentation
  needed" only (path MTU discovery from the 9000-byte VCN).
- MTU: 9000 inside the VCN (`vpc_mtu` default), 1500 to the internet. Pod MTU =
  `vpc_mtu - 50` (verified: node NIC 9000, pods 8950).

## Existing network

`vpc_id`, `public_subnet_id` and `private_subnet_id` (all three or none) deploy
into an existing VCN instead of creating one. Verified on 2026-11-16: plan
checks against a live VCN, one control plane in the existing private subnet,
`egress_ips` equal to the existing NAT address, destroy leaving the network. Set them before the first apply:
setting or clearing them later replaces the NSGs, the load balancer and the
nodes.

- Both subnets are regional (no availability domain) and belong to `vpc_id`.
- Public subnet (jumphost, NLB): public IPs allowed
  (`prohibit_public_ip_on_vnic = false`) and a `0.0.0.0/0` route to an internet
  gateway.
- Private subnet (nodes): a `0.0.0.0/0` route to a NAT gateway. Nodes reach the
  NLB public address through it, so its address is a client in the NLB NSG and
  the `egress_ips` output. Other egress paths (DRG, appliance) are rejected.
- The plan reads the route tables and NAT gateways in the VCN compartment; a
  route table or NAT gateway in another compartment fails the check.
- `vpc_cidr` becomes the VCN CIDR block: leave it null for the first block, or
  set one of the blocks. Both subnets must be inside it, and it must not overlap
  `10.42.0.0/16` or `10.43.0.0/16`. Traefik trusts proxy protocol from it.
- The module adds its four NSGs to the VCN and changes no security list, route
  table or gateway. Security lists of the subnets still apply: OCI allows a
  packet when a security list or an NSG allows it, so they can only open more.
  The stock default security list opens SSH (22) to 0.0.0.0/0: on subnets that
  use it, the jumphost and nodes are reachable on 22 whatever `admin_cidrs`
  says, so remove that rule. The lists need egress to the internet.
- Destroy leaves the VCN, subnets, gateways and route tables in place.
  `tools/leftovers/oci.sh` matches by the `elemental-cluster` tag, which they do
  not carry.

Find the OCIDs:

```bash
oci network vcn list -c <compartment-ocid> --all \
  --query 'data[].{name:"display-name",id:id,cidrs:"cidr-blocks"}' --output table
oci network subnet list -c <compartment-ocid> --vcn-id <vcn-ocid> --all \
  --query 'data[].{name:"display-name",id:id,cidr:"cidr-block",ad:"availability-domain",public:"prohibit-public-ip-on-vnic",rt:"route-table-id"}' --output table
```

## Nodes

One `oci_core_instance` per node, keyed by hostname (`<cluster>-cp-NN`,
`<cluster>-<pool>-NN`), in the private subnet, from the imported image. The
Ignition of the node is the base64 `user_data`; `ssh_authorized_keys` is also
set in the metadata (both together stay under 32000 bytes; the plan checks a
budget of 30976). Legacy IMDS endpoints are disabled (Ignition reads `/opc/v2/`).
Boot volumes: `control_plane_disk_size_gb` (default 100) and 200 GB for agents
unless a pool sets `disk_size_gb`; the boot volume is deleted with the instance
and uses the default 10 VPUs per GB. A new image replaces every node;
`metadata` is ignored after creation (Ignition runs on first boot only).

Placement: control planes go round-robin over `zones`; a pool without `zone`
spreads over `zones` the same way, a pool `zone` pins it. Inside an
availability domain the nodes of a group go round-robin over
`FAULT-DOMAIN-1..3`. The jumphost stays in the first zone.

Jumphost: it exists while the image is built and whenever `deploy_nodes` is
true (SSH bastion, `ProxyJump`). With `image_id` set it builds nothing and its
user_data holds only the ssh keys; with `image_id` set and `deploy_nodes =
false` there is none.

## Load balancer

A public network load balancer on a reserved public IP; listeners and backend
sets for 6443, 9345, 80 and 443. Backends are the control planes (instance
OCIDs) on every listener; Traefik and the API server run there.

Hairpin choice: control planes dial the NLB they back, through the NAT gateway
(the image knows one address). No backend set preserves the
client address (`is_preserve_source = false`), so the NLB sends the traffic from
its own address and the reply returns through it. `api_cidrs` and
`ingress_cidrs` are enforced by the NLB's NSG (rule keys
`nlb-client-<port>-<cidr>`), and the NAT gateway address is admitted on every
listener for the nodes. The control plane NSG admits only the NLB's subnet on
the listener and health check ports. Traefik and the access logs see the NLB's
address, not the client; the NLB sends no PROXY header, which Traefik accepts
from the trusted VCN CIDR. Health checks: TCP on 6443 for both API ports (9345 listens only
after the join) and Traefik's `/ping` on 8080 for ingress. Backends are created
in parallel.

## Labels

`freeform_tags` with the managed `elemental-*` keys on every taggable resource,
per [conventions](../conventions.md#labels). Tag keys allow `-`.

## GPUs

VM shapes `VM.GPU.A10.1` and `VM.GPU.A10.2` (service limit `gpu-a10-count`,
new tenancies start at 0); other VM GPU families are checked by name pattern
(`gpu<g>-count`) and are untested. GPU nodes are agents and carry the pool's
`gpu` role label. Each GPU shape of `gpu_pools` is made compatible
with the image through `oci_core_shape_management` (verified with it on
`VM.GPU.A10.1`; not tried without). The precompiled driver loads and
`nvidia-smi` runs in a pod (verified).

## Quota and availability

Plan-time hard fails:

- Each requested shape must be offered in its availability domain
  (`oci_core_shapes`).
- Service limits through `oci_limits_resource_availability`, per availability
  domain: `standard-e5-core-count` and `standard-e5-memory-count` (and the same
  pattern for other `E`/`A` flex families and `standard3`), `gpu-a10-count`;
  regionally `max-nlb-flexible-count` (service `network-load-balancer-api`) and
  `reserved-public-ip-count` (service `vcn`). What the cluster already holds is
  subtracted. Verified names: E5 and A10 only.
- Every node's shape is checked in its own availability domain; the quota is
  summed per domain from the node list (control planes, pools, jumphost while
  it exists).

Capacity can still run out at launch.

## Security

- The jumphost is the only SSH entry; it holds no OCI credential (write-only
  PARs). The PAR URLs sit in its user_data and in state; they expire after 24
  hours.
- Instances never read from Object Storage; the jumphost uploads only.
- The bucket is private.

## Cost estimate

`make cost PROVIDER=oci TFVARS=...` estimates the cost from tfvars
([tools/cost](../../tools/cost/README.md)). Rates come from the public Oracle
price list API (no key, cached; USD, no region dimension). It prices the
instances (flex shapes as `<shape>:<ocpus>x<memory_gb>`: OCPU-hours plus memory
GB-hours; fixed GPU shapes per GPU-hour), the boot volumes (block volume rate
plus 10 VPUs per GB, the default) and the custom image as Object Storage. The
network load balancer, reserved public IP, NAT gateway and VCN have no charge.
Outbound traffic (the first 10 TB per month are free) and the transient build
bucket are not included. The result is an estimate, not a quote.

## Leftover check

```bash
tools/leftovers/oci.sh <cluster_name> [--region <region>] [--compartment <ocid>] [--all]
```

Read-only. Uses the `oci` CLI and `jq`; credentials and the default region come from the CLI profile
(`OCI_CLI_*` variables work too), never the tfvars. `--region` overrides the profile region.
`deploy.sh` passes `region` and `oci_compartment_ocid` when set; `deploy.sh --destroy` prints the
command at the end and never runs it.

The core is one Search query for every indexed resource type carrying the cluster tag:

```text
query all resources where (freeformTags.key = 'elemental-cluster' && freeformTags.value = '<cluster_name>')
```

`--compartment` adds `&& compartmentId = '<ocid>'`. Rows in state `TERMINATED` or `DELETED` count as
gone (shown with `--all`); the Search index lags a few minutes, so a just-deleted resource can
briefly show another state. Deleted images can stay `AVAILABLE` in the index for over an hour, so
an image row is checked with `oci compute image get` (`DELETED` or not found is gone). The query
is paged (`--limit 1000`, `opc-next-page`): `structured-search` has no `--all`. Explicit checks cover what the tag query can miss: the
`<cluster_name>-build` bucket (by name) with its objects and pre-authenticated requests (objects and
PARs are not indexed), and, with `--compartment`, images named `<cluster_name>-*`. Not covered:
resources the Search index does not return for the tag (for example boot volumes that carry no
cluster tag; destroy removes them with their instance). Exit 0 means nothing is left, 1 something
is, 3 the check was inconclusive (CLI missing, search or namespace lookup failed).

## Operational limits

- OCI limits metadata to 32000 bytes.
- Jumphost image: the OL9 platform image ships `curl`; firewalld and SELinux are
  active, and the build only makes outbound connections.
- `keep_build_artifacts = true` leaves the qcow2 in the bucket; delete it
  before `terraform destroy` (`deploy.sh --destroy` prints the command:
  `oci os object bulk-delete --bucket-name <cluster_name>-build --prefix images/ --force`).
- A failed build leaves its qcow2 in the bucket: the next build writes other
  object names, and Terraform does not manage objects written through a PAR.
  Destroy then fails on the non-empty bucket; the same `bulk-delete` clears it.

## Verified on the first deploy

- UEFI boot of the imported image on `VM.Standard.E5.Flex` (no shape management)
  and `VM.GPU.A10.1` (with shape management).
- Ignition `oraclecloud` reads `user_data` (IMDS v2); the metadata precondition
  did not fire with the default components.
- NLB: control planes and agents join through the NLB address (6443, 9345)
  from the private subnet; health checks pass from the NLB subnet; Rancher
  answers on 443.
- Parallel backend creation (12 backends in one apply) without work-request
  conflicts.
- Pod MTU 8950 on VCN MTU 9000; GPU driver and `nvidia-smi`.
- `VM.GPU.A10.1` capacity in AD-1 on 2026-11-16.

## Still open

- Expired PARs after 24 hours (see Images).
- `oci_core_shape_management` needed or not for A10.
- Metadata size with every component enabled.
- Limit names for flex families other than E5 and for GPU families other than A10.

## Run it

The command runbook (tfvars layering, deploy, checks) is in
[`examples/oci/README.md`](../../examples/oci/README.md#end-to-end-runbook).

## Sources

- [Importing custom Linux images](https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/importingcustomimagelinux.htm)
- [Image capabilities for custom images](https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/configuringimagecapabilities.htm)
- [Ignition supported platforms](https://coreos.github.io/ignition/supported-platforms/)
- [oci_core_instance](https://registry.terraform.io/providers/oracle/oci/latest/docs/resources/core_instance)
