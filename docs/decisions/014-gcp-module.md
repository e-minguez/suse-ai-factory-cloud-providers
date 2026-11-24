# 014 - gcp module design

## Status
Accepted, implemented in `modules/gcp`. First real deploys passed on 2026-11-23
and 2026-11-24 (three control planes, L4 GPU node); open items in the
[platform notes](../providers/gcp.md#still-open) ([plan](../plans/gcp.md)).

## Context
Platform behaviour that shapes the module (checked in the [plan](../plans/gcp.md)
against provider `hashicorp/google` 8.x; the platform part is from the
documentation, not from a deploy):

- Custom images are global. `google_compute_image` takes a raw disk archive in
  Cloud Storage, a disk, a snapshot or another image. An image from a disk that
  is attached to a running VM needs the API flag `forceCreate`, which Terraform
  does not expose
  ([terraform-provider-google#1983](https://github.com/hashicorp/terraform-provider-google/issues/1983)).
  A snapshot of an attached disk is allowed.
- A VM can write small values (guest attributes) to its metadata server when
  `enable-guest-attributes` is `TRUE`. The Compute API reads them.
- One metadata value holds 256 KiB, and Ignition's `gcp` provider reads
  `user-data` from it without decompressing.
- A passthrough network load balancer delivers packets with the load balancer
  address as destination. The guest has to accept that address as local. The
  Google guest agent normally adds this route; the Elemental image has no guest
  agent.
- A forwarding rule has one address. One reserved internal address can be
  shared by several rules (purpose `SHARED_LOADBALANCER_VIP`). External and
  internal passthrough load balancers are separate resources.
- Passthrough health checks probe from fixed Google ranges.
- Quotas are per region (`regions.get`: metric, limit, usage) and per project
  (`projects.get`). The Cloud Quotas API reports limits only.
- Labels accept lowercase letters, digits, `_` and `-`. Firewall rules,
  routers, health checks, backend services, instance groups, VPCs and subnets
  take no labels.
- Machine types with built-in GPUs (G2, G4, A2, A3) carry the GPU in the type
  name. N1 takes attachable GPUs as a separate block.
- A third-generation or later machine family needs an NVMe boot disk, and the
  newest families accept Hyperdisk only.
- Public images exist for openSUSE Leap (project `opensuse-cloud`).

## Decision
- **One pass.** Both load balancer addresses are reserved first, then the image,
  then the instances, then the instance groups and backend services. No cycle,
  so `deploy.sh` is single pass.
- **Image through an attached disk, a snapshot and an image.** Terraform creates
  a blank persistent disk and attaches it to the jumphost. The jumphost writes
  the raw image with `dd` and `sync`. After the jumphost reports `done`,
  Terraform takes a snapshot of the disk and creates the image from the
  snapshot (`UEFI_COMPATIBLE`, `GVNIC`, `VIRTIO_SCSI_MULTIQUEUE`). The snapshot
  path avoids `forceCreate`. No object storage is involved, so no instance
  reads or writes a bucket and no signing identity is needed. Disk, snapshot and
  image names carry the build ID, so a new build never shows an old image
  through.
- **Build status in guest attributes.** The jumphost writes `aif/build_id`,
  `aif/state` (`building`, `done`, `failed`) and `aif/message`. A `local-exec`
  script on the operator machine reads them through the Compute API with the
  provider's access token (curl and jq, no `gcloud`). It sends the token to curl
  on stdin, so it is not in the process list. `failed` ends the wait at once.
  HTTP 401 ends it with a message to run `deploy.sh` again, because the token
  lives about an hour. No inbound firewall rule and no HTTP server are needed.
- **Two load balancer addresses.**
  - An external regional address on an external passthrough load balancer:
    6443 (`api_cidrs`), 80 and 443 (`ingress_cidrs`). Rancher, `api_host` and
    the sslip.io names use it.
  - An internal regional address in the node subnet on an internal passthrough
    load balancer: 6443 and 9345. It is `api_vip`, the address agents and
    joining control planes use. It is a shared address, so one address serves
    all its forwarding rules.
  - Both use the same unmanaged instance group per zone (the control planes of
    that zone). Both addresses are in the image.
  - A separate internal address avoids the hairpin the oci module accepts:
    nodes reach 9345 inside the VPC and keep their source address. The
    external address is still reached through Cloud NAT by nodes that dial
    their own ingress, so the NAT address is a client in the firewall rules.
- **Local routes, the internal one after rke2-server.** Control planes run
  `ip route replace to local <address> dev <primary interface> proto 66`
  (`local-routes.sh`, two systemd units from the new
  `local_route_addresses` and `local_route_addresses_after_server` options of
  `modules/elemental-config`). The external address is routed at boot, when the
  network is up. The internal address is routed only after `rke2-server` is
  active. With the route in place, a control plane that dials `api_vip` reaches
  itself and never leaves the host. A joining control plane must reach an
  existing server, so it must not have the route before its own server runs.
  After its server is active, the local backend can answer. The options are
  generic and empty by default, so no other provider changes.
- **Quota checks through the Compute REST API.** `data.http` reads
  `regions/<region>` and the project, with the provider's access token. The
  module sums the demand (CPUs or the family metric, GPUs, `GPUS_ALL_REGIONS`,
  SSD GB, static and in-use addresses), subtracts what the cluster already
  holds, and fails the plan in a postcondition that names the metric. Machine
  types are checked per zone with `google_compute_machine_types`. The Cloud
  Quotas API gives limits only, so it cannot show headroom. Checks are best
  effort: metrics the region does not list, Hyperdisk quotas and stockouts are
  not checked.
- **No service account on any instance.** Nodes and the jumphost read no object
  storage and call no Google API. The jumphost reports through guest
  attributes, which the metadata server accepts without credentials.
- **Plain-string machine types, built-in GPUs only.** `*_instance_type` stays a
  string (`n2-standard-4`, `g2-standard-4`, custom types
  `n2-custom-4-16384`). N1 with attachable GPUs would need a second field per
  pool in the module, the catalog and the cost tool. Fractional G4 sizes
  (`g4-standard-6`, `-12`, `-24`) fail the plan: they need the vGPU driver path,
  which is untested. The boot disk type and interface follow the machine family
  (`pd-balanced` and SCSI; `hyperdisk-balanced` and NVMe for C3, C4, N4, G4, A3
  and later; NVMe also on G2). GPU families and any `gpu_pools` node use
  `on_host_maintenance = TERMINATE`.
- **openSUSE Leap jumphost** from the public `opensuse-cloud` project (family
  `opensuse-leap`, override `jumphost_image`). `modules/image-factory` runs with
  `package_manager = "zypper"` and the image ships `curl`. The jumphost has a
  startup script that unpacks the config bundle and the factory script and runs
  them once; guest attributes are enabled, OS Login and project SSH keys are
  off, and SSH keys come from the `ssh-keys` metadata.
- **Zones are full names** (`europe-west4-a`), checked against the region and
  the zones that are up. Default region `europe-west4` (L4 and RTX PRO 6000 in
  zones a, b and c).
- **Network.** Custom-mode VPC, one regional subnet (`vpc_cidr`, default
  `10.20.0.0/20`), Cloud Router and Cloud NAT on a reserved address
  (`egress_ips`), MTU 1460 by default (`vpc_mtu` accepts 1300-8896; pod MTU is
  `vpc_mtu - 50`). Nodes have no public address unless requested. Firewall
  rules use network tags per role. Health checks are admitted from
  `35.191.0.0/16`, `130.211.0.0/22`, `209.85.152.0/22` and `209.85.204.0/22`.
- **Names and labels.** `cluster_name` is at most 30 characters, because
  resource names add a suffix and GCP limits names to 63. Labelled resources
  carry the common keys. Resources without labels are found by name prefix.
  `tags` must follow GCP label rules (lowercase), checked at plan.
- **Provider versions.** `hashicorp/google ~> 8.0` and `hashicorp/http ~> 3.4`.

## Alternatives considered
- **Raw image in Cloud Storage** (`raw_disk` as a tar.gz). It needs an object
  and a write path: a signed URL needs a signing key in Terraform, and an
  instance credential would break the rule that instances use no object
  storage. Kept only as a fallback if the snapshot path fails in a real deploy.
- **Image straight from the attached disk.** Needs `forceCreate`, which the
  provider does not expose. Stopping the jumphost and detaching the disk would
  add a second pass.
- **HTTP status relay on the jumphost** (as on evroc). Needs an inbound
  firewall rule and a Python server. Guest attributes need neither.
- **`gcloud` for polling and quotas.** Adds a CLI to the operator machine and
  the web UI image. `curl`, `jq` and the provider token are already there.
- **One load balancer address** (as oci). Control planes would join through
  Cloud NAT and the external address, and every join would come from the NAT
  address. The internal address keeps joins inside the VPC.
- **One internal address without the late route.** A joining control plane
  would load balance to itself and could not join.
- **Target pools** (legacy). The backend service model is current and gives
  per-listener health checks.
- **Cloud Quotas API for limits.** Does not report usage.
- **N1 with a `guest_accelerator` map or a type suffix.** More syntax in
  every tool for older GPUs that reach end of support in 2027.
- **IAP TCP forwarding instead of a jumphost.** Puts `gcloud` in the SSH path.
  The jumphost builds the image anyway.
- **SLES jumphost** (`suse-cloud`). Adds licence cost; Leap needs none.

## Consequences
- The deploy needs no Google credential on any instance and no object storage.
- The access token passed to the wait script lives about one hour from the plan.
  A build longer than that ends the wait with a rerun message; the jumphost
  keeps building.
- The `elemental-config` change affects only providers that set the new options.
  The addresses are in `build_hash`, so a new address rebuilds the image.
- `keep_build_artifacts` has no effect yet: the target disk and the snapshot stay
  until the next build or `terraform destroy`.
- Image creation from a disk or snapshot is rate limited by the platform. Quick
  `--rebuild` loops can hit it (not verified).
- Capacity (`ZONE_RESOURCE_POOL_EXHAUSTED`) cannot be checked at plan.
- Nothing here has run against a real project. The open items are in
  [the platform notes](../providers/gcp.md#still-open).
