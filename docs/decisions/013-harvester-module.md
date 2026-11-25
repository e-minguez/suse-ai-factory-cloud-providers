# 013 - harvester module design

## Status
Accepted. Implemented on `feat/harvester` (`modules/harvester`,
`examples/harvester`); end-to-end run pending
([plan](../plans/harvester.md), [platform notes](../providers/harvester.md)).

## Context
Platform behaviour that shapes the module (checked in the
[plan](../plans/harvester.md), Step 0, on Harvester 1.8.2 with provider
`harvester/harvester` 1.9):

- A volume can be exported to an image (`export-from-volume`) while the VM that
  wrote it is running. The image is the size of the whole volume.
- Harvester has no instance types, no security groups on VLAN networks and no
  public IPs. VM networks take their addresses from DHCP on the physical network.
- Ignition's `kubevirt` platform reads the NoCloud disk (Ignition 2.26 in the
  image) and does not decompress user_data. A Secret holds up to 1 MiB.
- The Elemental base OS ships qemu-guest-agent, started by udev when KubeVirt
  adds the agent port: Harvester reports node addresses (`wait_for_lease`).
- A VIP added with gratuitous ARP is reachable on the KubeVirt bridge from the
  network and from other VMs; without it the gateway keeps the old MAC for
  minutes.
- The provider has `node_selector` but no affinity fields, and adds a default
  preferred anti-affinity against every VM.
- Overlay (Kube-OVN) networks are not reachable from outside and ignore static
  addresses in cloud-init.

## Decision
- **One pass.** The VIPs are inputs and the image is exported from the volume the
  build host wrote, so no apply depends on an earlier created instance.
- **Image by disk export.** The build host writes the raw image with `dd` to a
  `harvester_volume` attached as a second virtio disk; a `harvester_image` of
  source type `export-from-volume` makes the node image. Harvester never fetches
  from the build host.
- **Build status over HTTP.** The factory hooks write
  `<build_id> <state> <detail>` to a file served by `python3 -m http.server` on
  the build host (port 8080); `wait-for-image.sh` polls it. No separate builders
  push to it, so no relay is needed.
- **Build host, powered off after the build** (`buildhost_power_off`,
  default true): it powers off once the `done` status was read, and the export
  reads the detached volume. There is no bastion: the runner reaches the VLAN
  anyway (status, VIPs), so `scripts/ssh.sh` connects to the nodes directly
  when the build host has no address. With `image_id` no build host exists.
  Harvester-owned names say `buildhost` (resources, VM, `buildhost_*`
  variables); the common `jumphost_*` variables and the `jumphost` output keep
  their names, identical in every provider.
- **Managed VIPs.** `api_vip_mode = "managed"` (MetalLB L2 and
  endpoint-copier-operator) exposes 6443 and 9345; `modules/elemental-config`
  adds an ingress pool (`ingress_vip`), an `L2Advertisement` and switches the
  ingress controller Service to `LoadBalancer` with
  `externalTrafficPolicy: Local`. `api_host` and the ingress hostnames default
  to sslip.io names on the VIPs.
- **Existing network only.** `vpc_id` is `<namespace>/<name>` of an L2 VLAN
  network and `vpc_cidr` its real subnet; the module creates no cluster-scoped
  network objects (shared clusters). Overlay networks are out of scope.
- **Sizes as `<vcpu>x<memory_gib>`.** `*_instance_type` stays a string, parsed
  in `locals.tf`.
- **Fixed MACs.** Derived from cluster and node name (`02:` prefix): stable DHCP
  addresses and a key for reservations.
- **CIDRs not enforced.** `admin_cidrs`, `api_cidrs` and `ingress_cidrs` are
  accepted and documented as not enforced.
- **Soft host spread.** The provider's default preferred anti-affinity, no
  `node_selector` pinning (it would block live migration during upgrades).
- **No gzip, 900000 bytes.** user_data is plain Ignition in a
  `harvester_cloudinit_secret`; `user_data_max_bytes = 900000`,
  `compress_node_files = false`.
- **Rejected at plan:** public IPs, `placement`, bare metal, `zones`.
- **GPU** pools use `host_device` with `gpu_devices`; passthrough enablement is
  cluster-scoped and not managed.

## Consequences
- The runner must reach the VLAN (build status, VIPs, SSH to the nodes).
- Short DHCP leases can move a control plane's address: reservations by MAC are
  recommended.
- Control planes can share a host.
- A VIP collision with an unleased address cannot be detected at plan.
- The node image is as large as `image_disk_size`.
- Host capacity cannot be checked at plan; there is no cost estimate.
- GPU passthrough is verified on control planes (one NVIDIA A10, 2026-11-25);
  GPU pools have not run on hardware.
