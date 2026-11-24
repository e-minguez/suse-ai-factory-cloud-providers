# Google Cloud (GCP) platform notes

Platform behaviour that decides how the GCP module is built. Run it:
[`examples/gcp/README.md`](../../examples/gcp/README.md). Decision record:
[ADR 014](../decisions/014-gcp-module.md). Plan:
[docs/plans/gcp.md](../plans/gcp.md).

**Status: experimental.** First real deploys on 2026-11-23 and 2026-11-24
(`europe-west4`, `asia-southeast1`): image build, three control planes behind
both load balancers, Rancher, aif-operator and an L4 GPU node work. What is
still unverified is listed in [Still open](#still-open).

## Limitations

- Machine types with built-in GPUs only (G2 with L4, G4 with RTX PRO 6000, A2,
  A3 1g). N1 with attachable GPUs (T4, V100) is not supported: instance types
  are plain strings.
- Fractional G4 sizes (`g4-standard-6`, `-12`, `-24`) fail the plan: the vGPU
  driver path is untested.
- `kind = "bare_metal"` and `placement` fail the plan.
- `cluster_name` is at most 30 characters.
- One region per cluster. Zones are full names (`europe-west4-a`).
- An existing network is read-only and must be in `gcp_project` (no Shared VPC
  host project); see [Existing network](#existing-network).
- The image does not use Secure Boot (`enable_secure_boot = false`).
- `keep_build_artifacts` has no effect yet: the target disk and the snapshot
  stay until the next build or `terraform destroy`.

## Prerequisites

### APIs

Enable `compute.googleapis.com` in the project. No other API is used by the
module. (`serviceusage.googleapis.com` is only needed to enable the Compute API
itself.)

```bash
gcloud services enable compute.googleapis.com --project <project-id>
```

### IAM roles

The identity that runs Terraform needs:

- `roles/compute.admin` on the project: instances, disks, snapshots, images,
  networks, firewall rules, routers, addresses, load balancers, and the read of
  quotas and guest attributes.
- `roles/serviceusage.serviceUsageAdmin` (or `serviceUsageConsumer` if the API
  is already enabled), so the Compute API can be used with the project.

The module creates no service account and no IAM binding. Instances run without
a service account.

### Credentials

Credentials come from Application Default Credentials. They never go in a
tfvars file.

```bash
gcloud auth application-default login
```

or `GOOGLE_APPLICATION_CREDENTIALS` pointing to a key file. If your
organisation blocks service account keys, use the login above, or
impersonate a service account that holds the roles:

```bash
gcloud auth application-default login --impersonate-service-account <sa-email>
```

The same token is used for the Compute API reads (quotas, guest attributes).
Set `gcp_project` to the project ID, not the name or number.

### Quotas

Request these before the first deploy; some need time. The console shows them
under IAM and admin, Quotas and system limits.

| Quota (metric) | Scope | Used for |
|---|---|---|
| `CPUS` or the family metric (`N2_CPUS`, `C3_CPUS`, ...) | region | vCPUs of all nodes and the jumphost |
| `gpus_all_regions` (`GPUS_ALL_REGIONS`) | project | every GPU, summed. New projects can start at 0. |
| `nvidia_l4_gpus` (`NVIDIA_L4_GPUS`) | region | G2 nodes |
| `gpus_per_gpu_family`, dimension `gpu_family` (for example `NVIDIA_RTX_PRO_6000`, `NVIDIA_H100`) and `region` | region | G4, A3 and newer GPUs. The default limit is 0. |
| `SSD_TOTAL_GB` | region | `pd-balanced` boot disks and the image target disk |
| `STATIC_ADDRESSES`, `IN_USE_ADDRESSES` | region | NAT, external and internal load balancer addresses; node public IPs |

The plan checks the quotas it can read (see [Quota and availability](#quota-and-availability)).

### Organisation policies

These constraints can block a deploy. Ask the project owner before you start.

- `constraints/compute.vmExternalIpAccess`: the jumphost needs an external IP
  and the external load balancer needs an external address. Allow the
  jumphost (or the project).
- `constraints/compute.trustedImageProjects`: the jumphost boots from
  `opensuse-cloud`. Add the project to the allow list, or set `jumphost_image`
  to an image from an allowed project.
- `constraints/gcp.resourceLocations`: the region of the deploy must be
  allowed. Images are stored in that region (`storage_locations`).

## Passes: 1, and why

Both load balancer addresses are reserved before the image. The image comes
before the instances, and the instance groups and backend services come after
the instances. No cycle, so one pass
([ADR 014](../decisions/014-gcp-module.md)).

## Images

1. Terraform creates a blank `pd-balanced` disk (`<cluster>-image-<build id>`,
   size from `image_disk_size`) and attaches it to the jumphost.
2. The jumphost (openSUSE Leap) builds the raw image with podman (`zypper`
   installs podman) and `dd`s it onto the disk, then `sync`. It reports
   through guest attributes in namespace `aif`: `build_id`, `state`
   (`building`, `done`, `failed`) and `message`.
3. `terraform_data.image_ready` runs `modules/gcp/scripts/wait-for-image.sh`
   on the operator machine. It polls `getGuestAttributes` through the Compute
   API with the provider's access token (curl and jq). `failed` stops the wait
   at once; HTTP 401 means the token expired (about one hour after the plan):
   run `deploy.sh` again, the build goes on. The timeout is 90 minutes.
4. `google_compute_snapshot` of the disk, then `google_compute_image` from the
   snapshot with `UEFI_COMPATIBLE`, `GVNIC` and `VIRTIO_SCSI_MULTIQUEUE`.
   Terraform cannot create an image from an attached disk
   ([forceCreate](../workarounds.md)), so the snapshot is the path.

Images are global: one image serves every zone, stored in the region
(`storage_locations`). Disk, snapshot and image names carry the build ID. The
image is rebuilt only when `build_hash` changes. `image_id` skips the chain.

The platform may limit how often images are created from one source disk. Two
`--rebuild` runs in a row (each with a new target disk and snapshot) were not
limited.

## Ignition and metadata

- `ignition.platform.id=gcp` (kernel command line
  `console=ttyS0,115200n8 ignition.platform.id=gcp`). Ignition reads the
  `user-data` metadata attribute from the metadata server and does not
  decompress it, so files are not compressed.
- One metadata value holds 256 KiB (262144 bytes). The module limits a node's
  Ignition to 245760 bytes (`user_data_max_bytes`) and fails the plan when a
  node is over its budget. The jumphost startup script has the same check.
- Nodes have a single NIC: `write-node-ip.sh` is not used.
- The image has no guest agent. SSH keys come from Ignition, not from the
  `ssh-keys` metadata. The jumphost has the guest agent of its Leap image and
  takes keys from `ssh-keys`; OS Login and project-wide keys are off.
- Nodes have no service account. Serial console output is on `ttyS0`
  (`gcloud compute instances get-serial-port-output`).

## Network

- Custom-mode VPC with one regional subnet (`vpc_cidr`, default
  `10.20.0.0/20`), routing mode regional.
- Cloud Router and Cloud NAT on one reserved address, which is the
  `egress_ips` output. All nodes reach the internet through it.
- MTU: 1460 by default (`vpc_mtu`, range 1300-8896). Pod MTU is `vpc_mtu - 50`.
  The default is the platform default for a custom VPC; a larger value is not
  tested.
- Firewall rules use network tags: `<cluster>-jumphost`,
  `<cluster>-control-plane`, `<cluster>-agent`. Rules:
  - SSH to the jumphost from `admin_cidrs`; SSH from the jumphost to nodes.
  - Kubelet, VXLAN and node ports, ICMP, and etcd between cluster members.
  - 6443 and 9345 on control planes from nodes (internal load balancer).
  - 6443 from `api_cidrs` and the NAT address; 80 and 443 from `ingress_cidrs`
    and the nodes (external load balancer). Nodes that dial the external
    address arrive from the NAT address, nodes with a public address from that
    address.
  - Health checks from `35.191.0.0/16`, `130.211.0.0/22`, `209.85.152.0/22` and
    `209.85.204.0/22`. The first covers both load balancer types; `130.211.0.0/22`
    is used by internal ones, `209.85.x` by external ones
    ([ranges](https://cloud.google.com/load-balancing/docs/health-check-concepts#ip-ranges)).
- The jumphost has an ephemeral public address and is the only SSH entry
  (`ProxyJump`, `scripts/ssh.sh`). Nodes have no public address unless
  `control_plane_public_ip` or a pool `public_ip` is true.

## Existing network

`vpc_id` (VPC network, name or self link) and `subnet_id` (regional subnet of
that VPC in `region`, name or self link), both or neither, deploy into an
existing VPC instead of creating one. Untested against a live project. Set them
before the first apply: setting or clearing them later replaces the network
objects, firewall rules, load balancers and nodes.

- The module creates no VPC, subnet, Cloud Router, Cloud NAT or NAT address, and
  reads the network and subnet with data sources. It still creates its own
  firewall rules (target tags), addresses, load balancers and instances in it.
- Both must be in `gcp_project`. A Shared VPC network of a host project is
  rejected: the firewall rules would have to live in the host project.
- Plan checks: the subnet is in `region`, belongs to `vpc_id`, `vpc_cidr` is
  null or equal to its primary range, the range is a /16 to /28, holds the
  nodes, the jumphost and the internal load balancer address, and does not
  overlap `10.42.0.0/16` or `10.43.0.0/16`. Traefik trusts proxy protocol from
  that range.
- `vpc_cidr` and the node-ip pinning use the subnet primary range. Secondary
  ranges are not used.
- Nodes are private: the subnet needs Cloud NAT egress (or another route to the
  internet) before the first boot. The module does not check it.
- The VPC MTU cannot be read. `vpc_mtu` (default 1460) sets the pod MTU
  (`vpc_mtu - 50`): set it to the MTU of the VPC when that is not 1460.
- Cloud NAT addresses cannot be read either. `nat_ips` lists them: they become
  the `egress_ips` output and the NAT client entries of the `lb-api` and
  `lb-ingress` firewall rules (nodes dial the external address through NAT; the
  load balancers keep the client address). Without `nat_ips`, `egress_ips` is
  empty and nodes behind the NAT cannot reach the external load balancer
  addresses (api_host, Rancher) until the NAT addresses are in `api_cidrs` and
  `ingress_cidrs`. Automatic NAT address allocation changes the address:
  reserve static ones for the NAT.
- `provider_details.router` is null and `nat_address` is the first of
  `nat_ips`.
- Destroy leaves the network in place. `tools/leftovers/gcp.sh` matches by
  name, so it suggests a VPC, subnet or router only when it is named like the
  cluster (`<cluster>` or `<cluster>-*`): do not name the existing network that
  way.

Find the values:

```bash
gcloud compute networks list --project <project>
gcloud compute networks subnets list --project <project> --network <vpc> --regions <region>
gcloud compute routers nats list --router <router> --region <region> --project <project>
gcloud compute routers get-nat-ip-info <router> --nat-name <nat> --region <region> --project <project>
```

## Nodes

One `google_compute_instance` per node, keyed by hostname (`<cluster>-cp-NN`,
`<cluster>-<pool>-NN`), from the global image. The Ignition of the node is the
`user-data` metadata value. `nic_type` is `GVNIC` (the jumphost uses it only
for families that require it, as its public image may not declare it). Boot
disk (default 100 GB for control planes, 200 GB for agents, `disk_size_gb` per
pool):

| Machine family | Boot disk type | Interface |
|---|---|---|
| e2, n1, n2, n2d, a2 and other second-generation | `pd-balanced` | SCSI |
| g2 | `pd-balanced` | NVMe |
| c3, c3d, c4, c4a, c4d, n4, g4, a3, a4, a4x | `hyperdisk-balanced` | NVMe |

GPU families (g2, g4, a2, a3 and later) and every node of a `gpu_pools` entry
use `on_host_maintenance = TERMINATE`. Others use `MIGRATE`. Nodes carry no
service account and Secure Boot is off.

A new image replaces every node (`replace_triggered_by`); `metadata` is ignored
after creation because Ignition runs on first boot only.

Defaults: control plane `n2-standard-4`, jumphost `e2-standard-4`. Control
planes go round-robin over `zones`; a pool without `zone` spreads over `zones`
the same way. The jumphost is in the first zone.

Jumphost: it exists while the image is built and whenever `deploy_nodes` is true.
With `image_id` set it builds nothing; with `image_id` set and `deploy_nodes =
false` there is none. Its image is `projects/opensuse-cloud/global/images/family/opensuse-leap`
(`jumphost_image` overrides it) and it ignores later changes of the family.

## Load balancer

Two regional passthrough network load balancers over the same control planes.
Backends are one unmanaged instance group per zone, holding that zone's control
planes. Deleting an instance removes it from its group, and its replacement has
the same self link, so an in-place update of the group's `instances` adds
nothing back and leaves the load balancers without backends. Each control plane
therefore has a `google_compute_instance_group_membership`, recreated with its
instance (`replace_triggered_by`). Removals run one at a time and wait for
connection draining, so the backend services set it to 0 (the 300 s default
made each removal take about six minutes).

| | Address | Ports | Used for |
|---|---|---|---|
| External | reserved external address | 6443 (`api_cidrs`), 80, 443 (`ingress_cidrs`) | Rancher, `api_host`, sslip.io names |
| Internal | reserved address in the subnet (`SHARED_LOADBALANCER_VIP`, one address for all rules) | 6443, 9345 | `api_vip`: agents and joining control planes |

Each port has its own forwarding rule, backend service and health check. API
ports use TCP checks; ingress ports use the check `modules/rke2-ports` defines
(Traefik `/ping` on 8080). The client address is preserved.

Local routes: a passthrough backend receives packets with the load balancer
address as destination and must treat that address as local. Without it the
guest drops the packets. The Elemental image has no guest agent, which usually
adds the route, so control planes add it themselves
(`ip route replace to local <address> dev <primary interface> proto 66`, see
[workarounds](../workarounds.md)):

- The external address at boot, after the network is up.
- The internal address only after `rke2-server` is active. A joining control
  plane must reach an existing server through the internal load balancer, not
  itself.

The options are `local_route_addresses` and
`local_route_addresses_after_server` of `modules/elemental-config`. Agents ignore
them. Both addresses are in the image (`build_hash`).

Hostnames: `rke2-<external address>.sslip.io` for the API and
`rancher-<external address>.sslip.io` for Rancher by default (both verified).
`api_host`, `rancher_hostname` and `ingress_domain` override them.

## Labels

`labels` with the managed `elemental-*` keys on every resource that takes them
(instances, disks, snapshots, images, addresses, forwarding rules), per
[conventions](../conventions.md#labels). GCP label rules: key 1-63 characters
starting with a lowercase letter; keys and values only lowercase letters, digits,
`_` and `-`; values up to 63 characters. `var.tags` is checked against them at
plan.

These types take no labels: VPC, subnet, firewall rules, router, NAT, health
checks, backend services and instance groups. The VPC, subnet, router and NAT are named
`<cluster_name>`, the others start with `<cluster_name>-`; `tools/leftovers/gcp.sh`
finds them by name.

## GPUs

G2 (one or more L4, `g2-standard-4` and up) and G4 (RTX PRO 6000, full-GPU
sizes `g4-standard-48` and up) are the targets; A2 and A3 1g types pass the
checks but are untested. GPU nodes are agents and carry the pool's `gpu` role
label. `europe-west4-a`, `-b` and `-c` offer both L4 and G4 (plan data, not
verified).

Verified on `g2-standard-4` (one L4) on 2026-11-24: the Elemental initrd boots
with `gve` and `nvme`, the precompiled SLES 16.1 driver loads, the operator's
CUDA validator completes, the node advertises `nvidia.com/gpu: 1` and
`nvidia-smi` lists the L4. G4 is untested.

### GPU capacity

Quota is not capacity. With enough GPU quota, instance creation can still fail
with `ZONE_RESOURCE_POOL_EXHAUSTED` (or `ZONE_RESOURCE_POOL_EXHAUSTED_WITH_DETAILS`)
when the zone has no free GPU capacity for that machine type. No API reports
capacity in advance, so the plan cannot check it: the error appears at apply,
on the GPU instance. Capacity changes over time, and a zone that fails now can
work an hour later.

What happened on 2026-11-24 in a new project: `g2-standard-8` was exhausted in
`europe-west4-a/b/c`, `europe-west1-b/c`, `us-central1-a/b`, `us-east4-a`,
`us-west1-a` and `asia-east1-a`; `g2-standard-4` was exhausted in the first 13
`asia-*` zones and then started in `asia-southeast1-c`, where the cluster was
deployed.

To find a zone, create and delete a throwaway instance in every zone that
offers the GPU, and stop at the first success. The probe instances have no
external address and are deleted immediately (billed per second). The snippet
creates a temporary auto-mode VPC, because projects can have no `default`
network:

```bash
gcloud compute networks create gpu-probe-net --subnet-mode auto --quiet

probe() {  # $1 = machine type, $2 = accelerator type (nvidia-l4, nvidia-rtx-pro-6000)
  for z in $(gcloud compute accelerator-types list --format='value(name,zone.basename())' \
               | awk -v a="$2" '$1==a{print $2}' | sort); do
    if out=$(gcloud compute instances create gpu-probe --zone "$z" --machine-type "$1" \
         --image-family debian-12 --image-project debian-cloud --network gpu-probe-net \
         --no-address --maintenance-policy TERMINATE --quiet 2>&1); then
      echo "STOCK: $1 $z"; gcloud compute instances delete gpu-probe --zone "$z" --quiet; return
    else echo "no:    $1 $z  $(tr '\n' ' ' <<<"$out" | grep -oE "[A-Z_]{8,}|Quota '[A-Z_0-9]+'" | head -1)"; fi
  done
}
probe g2-standard-4 nvidia-l4

gcloud compute networks delete gpu-probe-net --quiet
```

`QUOTA_EXCEEDED` instead of `ZONE_RESOURCE_POOL_EXHAUSTED` means the regional
GPU quota is missing, not capacity. A success says the zone had capacity at that
moment, not that it still has it at apply: deploy soon after. Smaller GPU sizes
(`g2-standard-4` instead of `-8`) found capacity sooner.

Then set `region` to the zone's region and pin the GPU pool to the zone. A pool
`zone` must be one of `zones`, and control planes spread over `zones` by index,
so list the zones once and change only the pool `zone` later: moving the pool
replaces the GPU nodes and nothing else.

```hcl
region    = "asia-southeast1"
zones     = ["asia-southeast1-a", "asia-southeast1-b", "asia-southeast1-c"]
gpu_pools = { gpu = { instance_type = "g2-standard-4", count = 1, zone = "asia-southeast1-c" } }
```

If the GPU instance still fails at apply, the control planes and the load
balancers come up anyway (they do not depend on the agents). Probe again, change
the pool `zone` or `instance_type` and rerun `./deploy.sh`.

Not supported by the module, and options when no zone has capacity: Spot VMs,
reservations (including calendar-mode future reservations), or asking Google
Cloud for capacity in a region.

## Quota and availability

Plan-time hard fails (`terraform_data.limits_check`):

- Each machine type must be offered in its zone
  (`google_compute_machine_types`). Custom types are not listed and skip this.
- Quotas read from the Compute API (`regions/<region>` and the project) with the
  provider's access token: `CPUS` or the family metric when the region lists
  one, the GPU metric of the type (`nvidia-l4` becomes `NVIDIA_L4_GPUS`),
  `GPUS_ALL_REGIONS`, `SSD_TOTAL_GB` for `pd-balanced` disks,
  `STATIC_ADDRESSES` and `IN_USE_ADDRESSES`. What the cluster already holds
  (found by the `elemental-cluster` label) is not counted again, so a re-plan
  does not fail on its own usage.
- A read failure of either call fails the plan with the HTTP status and the
  permission to check.

Not checked: metrics the region does not list, Hyperdisk quotas, quotas
that only the Cloud Quotas API measures (the `gpus_per_gpu_family` rows are
likely among them: not verified), and capacity
(`ZONE_RESOURCE_POOL_EXHAUSTED`, which can still fail at launch; see
[GPU capacity](#gpu-capacity)).

Input checks (`terraform_data.input_checks`): cluster name length, label rules,
machine type syntax, fractional G4, zones inside the region and up, CIDR, MTU.

## Security

- The jumphost is the only SSH entry. No instance has a service account.
- Nodes and the jumphost use no object storage. Build status travels in guest
  attributes, which need no credential on the instance.
- The access token used by the wait script goes to curl on stdin; the script
  never prints it. The provider's `google_client_config` data source holds the
  token in state (it expires after about an hour), another reason to treat state
  as secret.
- Terraform state holds the RKE2 token ([ADR 005](../decisions/005-state-secrets.md)).

## Cost estimate

`make cost PROVIDER=gcp TFVARS=...` estimates the cost from tfvars
([tools/cost](../../tools/cost/README.md#gcp)). Rates come from the Cloud Billing
Catalog API (USD, per region), which needs an API key in `GCP_PRICING_API_KEY`
(cached). It prices the machine types (vCPU, RAM and built-in GPU rates), boot
disks by type, the build disk, snapshot and image, external addresses, the
forwarding rules and Cloud NAT. The result is an estimate, not a quote.

## Leftover check

```bash
tools/leftovers/gcp.sh <cluster_name> [--project <project-id>] [--all]
```

Read-only. Uses `gcloud` and `jq`; credentials and the default project come from
the `gcloud` configuration, never the tfvars. It lists, by label
`elemental-cluster=<cluster_name>`: forwarding rules, instances, disks,
snapshots, images and addresses. By name (`<cluster_name>` or `<cluster_name>-*`): backend
services, health checks, instance groups, routers, firewall rules, subnets and
networks. It deletes nothing. A cluster whose name starts with `<cluster_name>-`
matches the name too: review the list before you delete anything. Exit 0 means nothing is
left, 1 something is, 3 the check was inconclusive. `deploy.sh --destroy` prints
the command and never runs it.

## Operational limits

- A failed build leaves the target disk (and a snapshot, if it got that far) in
  the project: the next build uses new names. `terraform destroy` removes what
  Terraform manages; check with the leftover script.
- The access token lasts about one hour from the plan. The wait for a build that
  takes longer ends with a rerun message.
- GPU capacity is not checked at plan: see [GPU capacity](#gpu-capacity).

## Verified

Deploys on 2026-11-23 (`europe-west4`, `n2-standard-4` control planes) and
2026-11-24 (`asia-southeast1`, plus one `g2-standard-4`):

- Image build: guest attribute polling with the access token, an image from a
  snapshot of the attached disk without a force flag, the global image.
  `build-logs.sh` reaches the jumphost during the build.
- `deploy_nodes = false` builds the image only; a later run with `true` adds the
  nodes.
- UEFI boot with the three guest OS features and `gve`/`nvme`; Ignition reads
  `user-data`; node hostnames are set.
- Local routes: the three control planes join through the internal load
  balancer (`api_vip`), and the external load balancer serves the API and
  Rancher, so health checks pass on both.
- sslip.io names serve Rancher (`/ping` 200) and the API (6443).
- Pod MTU 1410 with the default `vpc_mtu`.
- GPU operator with the precompiled driver on L4 (see [GPUs](#gpus)),
  `nvidia-smi` in a workload pod, a local-path volume, aif-operator 2.4.0. The
  aif-operator chart install retries until Rancher has installed the Fleet CRDs
  (about six minutes), then completes.
- A plan right after the deploy updates only `terraform_data.limits_check` (its
  stored quota demand drops to zero once the nodes exist); the next plan shows
  no changes.
- `deploy.sh --rebuild` twice in a row: no image rate limit, every node and the
  jumphost replaced, the control planes back behind both load balancers, the GPU
  node back with `nvidia.com/gpu: 1`; a plan afterwards shows no changes.
- Destroy in under five minutes (membership removals without draining), then
  `tools/leftovers/gcp.sh` reports nothing left.
- The test project's org policies allow external IPs, the custom image and both
  regions.

## Still open

- `precondition` messages: quota names match the metrics the API returns for L4,
  G4 and the machine families in use. Region data includes `gpus_per_gpu_family`
  or not. A quota that is too low fails the plan.
- Precompiled GPU driver on RTX PRO 6000.
- A worker pool.
- One control plane (`control_plane_count = 1`).
- NTP and MTU from DHCP on the node; a larger `vpc_mtu`.
- NAT address as a client for the external address is enough for in-cluster
  access to Rancher; the Cloud NAT address as `egress_ips` for multicluster
  registration.
- `image_id`.
- The existing network path.

## Sources

- [Ignition supported platforms](https://coreos.github.io/ignition/supported-platforms/)
- [Create custom images](https://cloud.google.com/compute/docs/images/create-custom)
- [Guest attributes](https://cloud.google.com/compute/docs/metadata/manage-guest-attributes)
- [Passthrough network load balancers](https://cloud.google.com/load-balancing/docs/passthrough-network-load-balancer)
- [Health check IP ranges](https://cloud.google.com/load-balancing/docs/health-check-concepts#ip-ranges)
- [terraform-provider-google#1983](https://github.com/hashicorp/terraform-provider-google/issues/1983)
- [google_compute_instance](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_instance)
