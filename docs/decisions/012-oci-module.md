# 012 - oci module design

## Status
Accepted. Implemented in `modules/oci` (network, load balancer, jumphost,
image, nodes, backends); first end-to-end run passed on 2026-11-16
([plan](../plans/oci.md), [platform notes](../providers/oci.md)).

## Context
Platform behaviour that shapes the module (checked in the
[plan](../plans/oci.md) and against provider `oracle/oci` 9.13):

- A network load balancer backend is a separate resource that targets an
  instance OCID, and a public NLB can take a reserved public IP. The address
  the image needs (apiVIP, hostnames) therefore exists before any instance.
- Custom images are imported from an Object Storage object (QCOW2 or VMDK).
  They boot with BIOS firmware unless an image capability schema sets
  `Compute.Firmware = UEFI_64`; launch mode PARAVIRTUALIZED.
- A pre-authenticated request (PAR) grants read, write or read-write on one
  object or bucket through a URL, without credentials.
- Instance `metadata` (with `user_data` in base64) is limited to 32000 bytes.
  Ignition's `oraclecloud` provider reads user_data from the metadata service
  and does not decompress it.
- Flex shapes take OCPUs and memory at launch; fixed shapes do not.
  Availability domain names carry a tenancy prefix.
- Bare metal shapes boot over iSCSI, which an imported image does not support.
- OCI platform images are Oracle Linux, not SUSE.

## Decision
- **One pass.** NLB and reserved IP, then the image, then the instances, then
  the backends: no cycle, so `deploy.sh` is single pass.
- **Upload through write-only PARs.** Terraform creates a private bucket and
  two PARs (`ObjectWrite` on the qcow2 and on a `done` marker). The jumphost
  uploads both with `curl -T` and holds no OCI credential, so no dynamic
  group or instance principal is needed. Terraform polls the marker through an
  `ObjectRead` PAR with `curl -sfI`; no `oci` CLI is in the deploy path. The
  PAR expiry is a `time_offset` keyed to `build_hash`, so plans do not drift.
- **Bucket cleanup.** Objects written through a PAR are not in state. After the
  image is imported, `oci_objectstorage_object` resources overwrite them with
  a one-line object (`ignore_changes = all`), so `destroy` deletes the objects
  and then the bucket. `keep_build_artifacts = true` skips the qcow2 overwrite;
  the bucket then has to be emptied before destroy.
- **UEFI by capability schema.** `oci_core_compute_image_capability_schema`
  sets `Compute.Firmware = UEFI_64` on the imported image;
  `oci_core_shape_management` adds the VM GPU shapes of `gpu_pools`.
- **VM GPU shapes only** (`VM.GPU.A10.1`, `VM.GPU.A10.2`); `kind = "bare_metal"`
  fails the plan.
- **Flex shape syntax.** Common `*_instance_type` stays a string:
  `<shape>:<ocpus>x<memory_gb>` for flex shapes (`VM.Standard.E5.Flex:4x32`), a
  plain name for fixed shapes. Parsed in `locals.tf`; a flex shape without a
  size, or a fixed shape with one, fails the plan. A provider-only map would
  need a second place to size every pool.
- **Jumphost on Oracle Linux 9**, installed with `dnf` through the
  `package_manager` option of `modules/image-factory`.
- **Zones are lowercase availability domain names** (`ad-1`): the common `zones`
  validation accepts lowercase only; they are resolved by suffix.
- **NSGs, not security lists.** The default security list allows egress and ICMP 3/4 (path MTU discovery) only.
- **user_data budget.** `user_data_max_bytes` is 22000 with per-file gzip
  (`compress_node_files`), leaving room in the 32000-byte metadata for the ssh
  keys.
- **Quota checks** read `oci_limits_resource_availability` per availability
  domain and subtract what the cluster already holds, so a re-plan does not
  fail on its own usage.

- **Nodes.** One `oci_core_instance` per node in the private subnet, no public
  IP (`control_plane_public_ip` and pool `public_ip` are rejected, as are
  `placement` and bare metal). Spread over the fault domains of each
  availability domain, and over `zones` when several are given.
- **Jumphost lifecycle.** It exists while the image is built and whenever nodes
  are deployed, because it is the only SSH entry. With `image_id` it carries
  no build payload.
- **Load balancer hairpin.** Control planes reach the API and supervisor
  through the public address (the image has a single address), so they are
  clients of the NLB they back. No backend set preserves the source (ingress
  included: in-cluster clients such as the Rancher agent reach Rancher through
  the NLB too): the NLB's address is the source at the backend, `api_cidrs` and
  `ingress_cidrs` are an NSG on the NLB, and the node NSGs admit the NLB's
  subnet. The NAT gateway address is admitted on the NLB for nodes. Cost:
  Traefik does not see client addresses. A private NLB address for in-cluster use would
  need a second join address in `elemental-config`; not done.
- **Ingress backends** are the control planes (Traefik hostPorts), health
  checked on `/ping` 8080; the NLB has no PROXY protocol.

## Consequences
- The deploy needs no OCI credential on any instance and no CLI on the
  operator machine.
- The write PAR URLs are in the jumphost's user_data, hence in state: state is
  secret (ADR 005). They expire after 24 hours.
- Quota limit names are verified for the `E5` and `A10` families; other flex
  families follow the same pattern and fail the plan if a name is wrong.
  Other families are not checked.
- Capacity ("Out of host capacity") cannot be checked at plan.
- Bare metal GPU shapes need an iSCSI-capable image: a later change.
