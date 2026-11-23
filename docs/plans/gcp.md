# Plan: Google Cloud (GCP) provider

Status: implemented and validated against mocked providers (2026-11-23) on
`feat/gcp`; documentation written ([ADR 014](../decisions/014-gcp-module.md),
[platform notes](../providers/gcp.md)). No project access yet (IAM pending),
Step 0 not run, no real deploy. The section "Decisions for v1" overrides earlier
options in this file; "Implementation status" lists what exists.

Goal: `modules/gcp` + `examples/gcp` at parity with aws, evroc, exoscale, oci
and vultr: same common variables, outputs, labels, `deploy.sh` interface,
plan-time quota/availability hard-fails, cost estimate, leftovers script,
catalog plans, CI job, webui entry.

## Naming

Provider directory and identifier: **`gcp`** (Terraform provider
`hashicorp/google`, current v8.12.0). Docs title: "Google Cloud (GCP)".
Ignition platform id is also `gcp`.

## Facts checked (2026-11-20, docs only, not tested)

Items marked **[verify]** come from one source or from inference.

- **Ignition**: platform `gcp` reads metadata attribute `user-data` from
  `http://169.254.169.254/computeMetadata/v1/instance/attributes/user-data`
  (`Metadata-Flavor: Google`). The provider does **not** gunzip, so if
  compression is needed, use per-file gzip (`compress_node_files`), as on oci.
- **user_data limit**: one metadata value can be 256 KB and all values
  together 512 KB. Much more than EC2 (16 KiB) or OCI (32,000 bytes), so
  compression is probably not needed. `user_data_limit` = 256 KiB minus margin.
- **No guest agent** in the Elemental image. The agent normally handles
  `ssh-keys` metadata, OS Login and the local route for load balancer IPs.
  SSH keys already come from Ignition `passwd`. The LB route needs a new script
  (see Load balancer).
- **Images are global**: one `google_compute_image` serves every region and
  zone of the project. No per-zone copies (unlike evroc/exoscale snapshots).
  `storage_locations` = region of the deploy.
- **Image sources**: `google_compute_image` accepts `raw_disk` (GCS tar.gz
  only), `source_disk`, `source_snapshot` or `source_image`. An image from a
  disk **attached** to a running VM needs API `forceCreate`, which Terraform
  does not expose ([terraform-provider-google#1983](https://github.com/hashicorp/terraform-provider-google/issues/1983),
  open since 2018). A snapshot of an attached disk is allowed, and an image
  can then be created from that snapshot. **[verify]** that image-from-snapshot
  never needs force.
- **Rate limit**: one image per source disk every 10 minutes **[verify]**
  scope. Affects quick `--rebuild` loops only.
- **guest_os_features**: `UEFI_COMPATIBLE`, `GVNIC`, `VIRTIO_SCSI_MULTIQUEUE`
  (same core set as Fedora CoreOS GCP images). Secure Boot: not with our
  image (unsigned shim path untested), leave Shielded VM secure boot off.
- **Kernel requirements**: virtio, `ttyS0` serial, **NVMe** boot disk for G2
  and every third-generation or later family, **gVNIC** (`gve`, mainline since
  5.3) for third-generation and later. The Elemental initrd must contain
  `nvme` and `gve` **[verify]**.
- **Serial console**: readable through data source
  `google_compute_instance_serial_port` or `gcloud compute instances
  get-serial-port-output`. Kernel cmdline `console=ttyS0,115200n8`.
- **Guest attributes**: with metadata `enable-guest-attributes=TRUE`, a VM can
  `PUT` small values to its metadata server, and Terraform/REST/gcloud can read
  them. Gives build status from the jumphost with no HTTP server and no
  inbound firewall rule.
- **MTU**: VPC default 1460, range 1300–8896, sent by DHCP option 26. Changing
  it requires stopping all VMs. Pod MTU = `vpc_mtu − 50`.
- **Labels**: key 1–63, value 0–63 chars, lowercase letters, digits, `_`, `-`
  only, key starts with a letter. The `elemental-*` keys fit. `var.tags` needs
  a lowercase validation for gcp (uppercase values fail at apply otherwise).
  Network tags (firewall targets) are a separate concept from labels.
- **Auth**: Application Default Credentials (`gcloud auth
  application-default login` or `GOOGLE_APPLICATION_CREDENTIALS`), optional
  `impersonate_service_account`. No secrets in tfvars. Many orgs block service
  account key creation by policy **[verify]**: support both.
- **APIs to enable**: `compute.googleapis.com`; `cloudquotas.googleapis.com` if
  the Cloud Quotas data sources are used; `iap.googleapis.com` only if IAP SSH.
- Nodes can run **without a service account** (omit `service_account`), so no
  instance reads object storage or calls Google APIs.

### GPU families (late 2026)

| Family | GPU | Smallest | Boot disk | NIC | Notes |
|---|---|---|---|---|---|
| N1 + `guest_accelerator` | T4, V100, P4 | n1-standard-4 + 1×T4 | pd-* | virtio | T4/P4 end of support 2027-08-01 |
| G2 | L4 24 GB | g2-standard-4 (1×L4) | pd-balanced, pd-ssd (no pd-standard) | gVNIC | NVMe required |
| G4 | RTX PRO 6000 Blackwell | g4-standard-6 (1/8 GPU) | Hyperdisk Balanced only, no PD | gVNIC **[verify]** | fractional to 8 GPUs |
| A2 | A100 40/80 GB | a2-highgpu-1g | pd-* | | |
| A3 High | H100 | a3-highgpu-1g | | gVNIC | 1g/2g/4g only Spot or Flex-start |
| A3 Ultra, A4, A4X | H200, B200, GB200 | 8 GPUs | Hyperdisk Balanced | RDMA | reservation/Spot/Flex-start, out of scope |

- All GPU VMs: `scheduling.on_host_maintenance = "TERMINATE"`.
- Targets for v1: **G2 (L4)** and **G4 (RTX PRO 6000)**; N1+T4 as cheap
  fallback for tests. A2/A3-1g later.
- Boot disk type must follow the family: derive a default per machine family in
  `locals.tf` (pd-balanced for n1/n2/g2/a2, hyperdisk-balanced for g4/c3/n4/a3),
  with a provider-only override variable.
- `provisioning_model` STANDARD | SPOT | FLEX_START: v1 only STANDARD, SPOT as
  an optional per-pool provider variable later.
- Quota metrics (seen in the console 2026-11-23): global `gpus_all_regions`;
  per region `nvidia_l4_gpus`, `nvidia_t4_gpus` etc. for older GPUs;
  `gpus_per_gpu_family` with dimensions `gpu_family` (`NVIDIA_RTX_PRO_6000`,
  `NVIDIA_H100`, `NVIDIA_H100_MEGA`, `NVIDIA_H200`, `NVIDIA_B200`) + `region`
  for newer GPUs. Its default system limit is 0 and not adjustable; regional
  quota rows are requested per region/family. New projects can start with
  `gpus_all_regions = 0`; the test project has 12,000.

## Step 0: blockers (manual, once access exists)

1. **Quota requests**, first thing (they take time): `GPUS_ALL_REGIONS` ≥ 2,
   regional `nvidia_l4_gpus` and/or `gpus_per_gpu_family` (`NVIDIA_RTX_PRO_6000`)
   (and `NVIDIA_T4_GPUS` for cheap tests) in the target region, `CPUS`,
   `IN_USE_ADDRESSES`, `STATIC_ADDRESSES`. Pick region/zones from the L4/G4
   zone list (e.g. `europe-west4-a/b/c` have both).
2. Elemental image: `gve` and `nvme` modules present in the initrd
   (`lsinitrd` on the built raw, or boot test below). If missing: SUSE request
   + `docs/workarounds.md`.
3. Manual boot test: `dd` the current raw (same as evroc) onto a blank PD
   attached to a throwaway VM, snapshot it, image from snapshot with the three
   guest_os_features, launch one `n2-standard-4` (virtio) and one
   `g2-standard-4` (NVMe + gVNIC) with a minimal Ignition in `user-data`.
   Check: UEFI boot, Ignition fetches config, NIC up by DHCP, MTU, hostname
   from DHCP, NTP (metadata server 169.254.169.254 via DHCP), serial output.
4. Same image on `g2-standard-4` and `g4-standard-48` (or the smallest full-GPU
   G4): GPU visible, precompiled SLES 16.1 driver loads. Fractional G4 (vGPU)
   needs a different driver path: test separately, may be unsupported.
5. Quota read path: does `regions.get` return `quotas[]` with the
   `NVIDIA_L4_GPUS` and per-GPU-family metrics (limit + usage)? Decides the availability design.
6. NLB local route: confirm the backend drops traffic to the LB IP without
   `ip route add to local <LB_IP> dev <if>`, and works with it.

### Results

- 2026-11-23, 0.1: `gpus_all_regions` = 12,000 (0 used). `nvidia_t4_gpus`
  16 in europe-north1 and most large regions, 1 in small ones. L4 and
  RTX PRO 6000 regional values: pending.

Record results here (date + outcome), then go on.

## Design

### Passes: 1 (like aws and oci)

Reserved static regional address → address in the image config (sslip.io
hostnames, tls-san, LB local route) → image → instances → instance groups and
backend service. No cycle. Image built through a snapshot of an attached disk
(next section), so no detach pass either. `deploy.sh` keeps the common
interface. ADR **014** (011 baremetal branch, 012 oci, 013 harvester; note
`feat/exoscale-public-network` also uses 012).

### Auth and provider variables (`modules/gcp/variables.tf`)

- `gcp_project` (in `common-gcp.tfvars`), optional
  `gcp_impersonate_service_account`. Credentials only via ADC env, never
  tfvars.
- `region` = GCP region (`europe-west4`). `zones` = zone suffixes or full names
  (`europe-west4-a`); decide in the ADR (oci uses short AD names `ad-1`,
  others use full names: prefer full names, they are already unique).

### Machine types

Plain strings (`g2-standard-4`, `n2-standard-4`). Custom machine types
(`n2-custom-4-16384`) are already strings. N1 + attachable GPUs need a GPU
type and count: provider-only map `gpu_accelerators = { <pool> = { type =
"nvidia-tesla-t4", count = 1 } }` or a suffix syntax
(`n1-standard-8+nvidia-tesla-t4:1`); decide in the ADR. The cost tool must
parse the same thing.

### Network (`network.tf`, `firewall.tf`)

- Custom-mode VPC (`auto_create_subnetworks = false`, `mtu = var.vpc_mtu`),
  one regional subnet (`vpc_cidr`), Cloud Router + Cloud NAT for private node
  egress.
- Firewall rules by network tag per role: `<cluster>-jumphost`,
  `<cluster>-control-plane`, `<cluster>-agent`. Intra-cluster rules from
  `modules/rke2-ports`. `admin_cidrs` → jumphost 22; `api_cidrs` →
  6443/9345 on control planes; `ingress_cidrs` → 80/443. NLB health checks
  from 35.191.0.0/16, 209.85.152.0/22, 209.85.204.0/22 (keep in a local, link
  the doc).
- Nodes private by default; jumphost has a public IP and is the SSH entry
  (`scripts/lib/ssh.sh` ProxyJump, unchanged). IAP TCP forwarding (no
  jumphost) is a possible follow-up, not v1: it puts `gcloud` in the SSH path.
- Single NIC → `write-node-ip.sh` no-op. `vpc_mtu` default 1460 for v1; test
  8896 in Step 0 and switch the default if pods and NLB traffic work.
- Existing VPC/subnet (`vpc_id` + `subnet_id`, must have Cloud NAT): follow-up
  PR, same shape as the other providers.

### Load balancer (`loadbalancer.tf`)

- Regional **external passthrough NLB, backend-service based** (target pools
  are legacy). `google_compute_address` (EXTERNAL, regional) reserved first;
  forwarding rules for 6443, 9345, 80, 443 on that address; one
  `google_compute_region_backend_service` per listener (or one with
  `L3_DEFAULT`/port list, decide by health checks); regional TCP health checks.
- Backends: one `google_compute_instance_group` (unmanaged) per zone holding
  that zone's control planes. Source IP preserved, direct server return.
- **Local route on every backend** for the LB address. New elemental-config
  option (e.g. `lb_local_addresses = [ip]`) writing a script + systemd oneshot
  that runs `ip route replace to local <ip> dev <primary if> proto 66` after
  the network is up. Generic, off for other providers. Address feeds
  `build_hash` (it is in the image).
- Agents join on 9345: through the NLB address they leave via Cloud NAT and
  arrive from the NAT IP (must be allowed, and hairpin works only for
  non-backends). Alternatives: an internal passthrough NLB (second forwarding
  rule, internal address) or the first control plane's private IP, as other
  providers do. Decide by testing; check what the oci module ended up using.
- Hostnames: `<ip>.sslip.io` for Rancher and the API (verify in first deploy).

### Image pipeline (`build.tf`, `image.tf`)

Recommended: **dd onto a PD, snapshot, image** (no GCS, no new exception to
the "instances do not read or write object storage" rule).

1. Jumphost from a public SUSE-family image (`opensuse-cloud` Leap or
   `suse-cloud` SLES; check which projects/families exist and licence cost),
   so `modules/image-factory` uses `zypper` as is. Builds the raw with the
   shared factory templates.
2. A blank `google_compute_disk` (`image_target`, size ≥ raw) attached to the
   jumphost as a secondary disk; the jumphost `dd`s the raw onto it, `sync`s,
   then reports `build_id` done (or failed) as a **guest attribute**.
3. `terraform_data.image_ready` local-exec polls the guest attribute. Options:
   `curl` to the REST `getGuestAttributes` with a token from
   `data.google_client_config.access_token` (expires after ~1 h; builds take
   ~6–20 min, so fine, but refresh if `TIMEOUT_SECONDS` > 1 h) or `gcloud` (adds
   a CLI dependency, as aws needs `aws`). Prefer curl + token: no extra CLI in
   the webui image. A failure value stops the wait at once (the open oci
   follow-up, solved here from day one).
4. `google_compute_snapshot` of the attached `image_target` after
   `image_ready`, then `google_compute_image` (`source_snapshot`,
   `guest_os_features`, `storage_locations = [region]`, labels incl. `build`).
   Name carries `build_hash`.
5. `keep_build_artifacts = false`: delete the snapshot after the image exists
   and stop/delete the jumphost when no nodes need it (match the oci rule:
   jumphost exists while it builds or nodes exist).
6. `image_id` skips the chain, as in aws/oci.

Fallback if image-from-snapshot fails: raw tar.gz to a GCS bucket via a
write-only signed URL (like the oci PAR). Needs a signing identity in
Terraform (`google_storage_object_signed_url` wants a key) and a CLAUDE.md
exception: avoid unless needed.

### Nodes (`control-plane.tf`, `agent-nodes.tf`)

- `google_compute_instance` per node (per-node user_data, single pass), zones
  round-robin per pool. `metadata = { user-data = <ignition> }`, no
  `ssh-keys`, no service account, `enable-guest-attributes` only on the
  jumphost.
- `boot_disk.initialize_params.image = image`, type per family, `interface =
  NVME` where required; `network_interface.nic_type = GVNIC` for families that
  require it (or always, if Step 0 shows `gve` works).
- GPU: `on_host_maintenance = TERMINATE`, `automatic_restart = true`; N1 uses
  `guest_accelerator`.
- Image change must replace instances: check whether the provider replaces on
  `boot_disk.initialize_params.image` change (it does: ForceNew) or, like oci,
  needs `replace_triggered_by`.
- `control_plane_public_ip`/`agent_public_ip`: `access_config {}` on demand,
  same semantics as aws.

### Labels (`docs/conventions.md#labels`)

`labels` with the `elemental-*` keys + `role`, `pool`, `build`, `listener` on
every labelable resource (instances, disks, images, snapshots, addresses,
forwarding rules). Firewall rules, routes, VPCs, subnets, instance groups and
backend services take **no labels** **[verify per resource]**: put cluster
name in their `name`/`description` and document the gap in
`docs/providers/gcp.md` (leftovers must match those by name prefix).

### Quota and availability (`availability.tf`, hard-fail)

- Machine type offered in its zone: `data "google_compute_machine_types"`
  (zone + filter `name = "<type>"`), postcondition non-empty. Its
  `accelerators[]` gives the GPU count of G2/G4/A-series. N1 attachable GPUs:
  zone `acceleratorTypes.list` via `data "http"` + access token (no data
  source exists).
- Quotas: `data "http"` on `regions/<region>` (fields `quotas[].metric`,
  `limit`, `usage`) and `projects/<project>` for `GPUS_ALL_REGIONS`. Compare
  requested totals (CPUS, GPU family, IN_USE_ADDRESSES, STATIC_ADDRESSES,
  disk GB per type) with `limit − usage`. The Cloud Quotas data sources give
  limits only, so they are not enough. Precondition messages name the quota
  metric so the user can request it.
- Stockouts (`ZONE_RESOURCE_POOL_EXHAUSTED`) cannot be checked: document.

### Outputs

Identical set (`docs/conventions.md#outputs`); project, VPC, subnet, address,
backend services, image self-link in `provider_details`.

## Tooling and repo touchpoints

- `modules/gcp/variables-common.tf` symlink; `examples/gcp/{main,variables,
  outputs,versions}.tf`, `deploy.sh`, `terraform.tfvars.example`, README.
- Tests: `mock_provider "google"` (+ `http` for quota calls); complete mock
  values for tofu; `make tofu-tests-gen`; `catalog.tftest.hcl` mocked
  availability list.
- `catalog/<NN-shape>/gcp/README.md` + tfvars: map GPU shapes to G2 (L4) and
  G4 (RTX PRO 6000), mark shapes needing 8-GPU families unsupported.
- `tools/leftovers/gcp.sh` on `scripts/lib/leftovers.sh`: `gcloud compute
  {instances,disks,images,snapshots,addresses,forwarding-rules} list
  --filter=labels.elemental-cluster=<name>` plus name-prefix lists for
  unlabelled types (firewall rules, routers, instance groups, backend
  services, health checks, networks). Cloud Asset `search-all-resources` is
  simpler but needs another API. Suggested, never run, + test.
- `tools/cost`: Cloud Billing Catalog API (`services/6F81-5844-456A/skus`) needs
  an **API key** (no IAM); read it from an env var, cache like oci, fail with a
  clear message when unset. VM price = vCPU SKU + RAM SKU + GPU SKU per family
  and region (+ PD/Hyperdisk GB, static IP, NLB forwarding rule, Cloud NAT).
  `TestDefaultsMatchLocals`. Check SKU coverage of G4 before coding.
- `tools/webui/ui.yaml` `gcp:` block (project; ADC file path mounted read-only
  into the volume, never shown); Dockerfile: provider mirror comes from
  `terraform get`; no gcloud for v1 if the curl + token design holds.
- CI: matrix gains `gcp` → required check `validate (gcp)` (18 checks, admin
  `gh api` from README).
- Makefile cost help, leftovers loop, deploy tests.
- Docs: `docs/providers/gcp.md` (same headings as oci.md), architecture
  diagrams (image pipeline via snapshot, NLB with local route), README
  provider table, CLAUDE.md provider facts (user_data limit, platform id,
  passes, guest attributes, local route), ADR 014, `docs/e2e-checklist.md`
  gcp column.

## Decisions for v1 (2026-11-23, defaults pending user review)

These replace the open questions; implementation follows them.

1. **Region**: default `europe-west4` (L4 and G4 in zones a, b, c). `zones`
   are full zone names (`europe-west4-a`); default follows the other
   providers' zone defaults.
2. **GPUs**: v1 supports machine types with built-in GPUs only (G2 L4, G4
   full-GPU sizes, A2, A3 1g). N1 + `guest_accelerator` (T4/V100) is out of
   scope, so `*_instance_type` stays a plain string everywhere (module, cost
   tool, catalog). Fractional G4 (`g4-standard-6/12/24`) rejected at plan
   (vGPU driver path untested).
3. **Jumphost image**: openSUSE Leap from the public `opensuse-cloud` image
   project (latest family, verify the family name), override
   `jumphost_image`. `modules/image-factory` keeps `package_manager = "zypper"`.
4. **Joins and API**: two load balancer addresses, both reserved before the
   image:
   - external regional address + external passthrough NLB: 6443
     (`api_cidrs`), 80/443 (`ingress_cidrs`). Rancher, `api_host` and sslip
     names use it.
   - internal regional address (node subnet) + internal passthrough NLB: 6443
     and 9345. This is `api_vip` (agents and joining control planes).
   - Both use the same per-zone unmanaged instance groups of control planes.
   - Control planes add local routes (`ip route replace to local <ip> dev
     <primary if> proto 66`): the external address at boot (network up), the
     internal address only **after `rke2-server` is active**, so a joining
     control plane reaches an existing server through the internal LB, not
     itself. Generic, default-off option in `modules/elemental-config`
     (control planes only). Verify in Step 0.
   - Health checks: TCP 6443, TCP 9345, ingress as the other providers.
5. **Build status**: guest attributes (`enable-guest-attributes=TRUE` on the
   jumphost; namespace `aif`, keys `build_id`, `state` =
   `building|done|failed`, `message`). `terraform_data.image_ready` local-exec
   runs `modules/gcp/scripts/wait-for-image.sh` (curl + jq on
   `instances/<name>/getGuestAttributes`), token from
   `data.google_client_config` passed with `nonsensitive()` (a sensitive env
   suppresses the script output; the script never prints it). HTTP 401 ends
   with a message to rerun `deploy.sh` (token lifetime ~1 h from plan).
   `failed` ends the wait at once.
6. **Image**: blank `google_compute_disk` attached to the jumphost, jumphost
   `dd` + `sync`, then `google_compute_snapshot` → `google_compute_image`
   (`source_snapshot`, `guest_os_features` UEFI_COMPATIBLE, GVNIC,
   VIRTIO_SCSI_MULTIQUEUE, `storage_locations = [region]`). Single pass, no
   GCS.
7. **Nodes**: `google_compute_instance` per node, no service account, metadata
   `user-data` only, `nic_type = GVNIC`, boot disk interface NVME where the
   family needs it, disk type by family (pd-balanced: n1, n2, n2d, e2, g2, a2;
   hyperdisk-balanced: c3, c3d, c4, n4, g4, a3), override variable. GPU types:
   `on_host_maintenance = "TERMINATE"`.
8. **Quota**: `data "http"` on Compute `regions/<region>` (limit, usage) and
   `projects/<project>` (`GPUS_ALL_REGIONS`); machine types via
   `data "google_compute_machine_types"` per zone. Postconditions hard-fail.
9. **Cost tool**: Cloud Billing Catalog API with an API key from env
   `GCP_PRICING_API_KEY`; clear error when unset; cache as oci.
10. **ADR 014**. Provider `hashicorp/google` `~> 8.0` (+ `hashicorp/http`).

Open for the user: confirm these defaults; org policies of the project
(external IPs, trusted image projects, resource locations).

## Implementation status

Updated 2026-11-23. Mocked tests only; nothing ran on Google Cloud.

- [x] `modules/gcp`: network, firewall, Cloud NAT, two load balancers, image
      pipeline (disk, guest attributes, snapshot, image), nodes, quota and
      availability checks, outputs.
- [x] `modules/elemental-config`: `local_route_addresses` and
      `local_route_addresses_after_server` with `local-routes.sh`.
- [x] `tools/leftovers/gcp.sh` and its test.
- [x] Docs: ADR 014, `docs/providers/gcp.md`, architecture, conventions,
      workarounds, e2e checklist, README, CLAUDE.md.
- [x] `examples/gcp` (`deploy.sh`, tfvars example, README).
- [x] `catalog/` guides and tfvars for gcp, plans in `catalog.tftest.hcl`.
- [x] `tools/cost` gcp provider (Cloud Billing Catalog API, `GCP_PRICING_API_KEY`).
- [x] CI matrix entry (`validate (gcp)`).
- [ ] `validate (gcp)` in the ruleset (18 required checks; admin, after merge).
- [x] Web UI entry (`ui.yaml`, ADC credentials, leftovers job).
- [ ] `keep_build_artifacts` effective (delete snapshot and target disk).
- [ ] Existing network (`vpc_id`, `subnet_id`).
- [ ] Step 0 and the first end-to-end run (see `docs/e2e-checklist.md`).
