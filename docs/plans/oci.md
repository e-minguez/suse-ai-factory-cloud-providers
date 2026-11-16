# Plan: Oracle Cloud Infrastructure (OCI) provider

Status: implemented (`modules/oci`, `examples/oci`); first end-to-end run
passed on 2026-11-16 ([results](oci-e2e.md), open items in
[docs/providers/oci.md](../providers/oci.md)). Step 0 (Ignition version, UEFI
boot of an imported image) passed.

Goal: `modules/oci` + `examples/oci` at parity with aws, evroc, exoscale and
vultr: same common variables, outputs, labels, `deploy.sh` interface, plan-time
quota/availability hard-fails, cost estimate, leftovers script, catalog plans,
CI job, webui entry.

## Naming

Provider directory and identifier: **`oci`** (Terraform provider
`oracle/oci`, CLI `oci`, short like `aws`). Docs title: "Oracle Cloud (OCI)".
Change before Step 1 if `oracle` is preferred; it touches every path below.

## Facts checked (2026-11-13)

- **Ignition**: `oraclecloud` is a supported platform (config from instance
  userdata, SSH keys handled separately). Added in Ignition **2.22.0**
  (2025-07-08); an older 0.x provider was removed in 0.25.0. Kernel arg
  `ignition.platform.id=oraclecloud`.
- **user_data limit**: metadata + extendedMetadata together ≤ **32,000 bytes**
  (`user_data` is base64 inside metadata, so the raw Ignition budget is
  ~23 KiB minus `ssh_authorized_keys`). Not checked at plan by the provider;
  launch fails with `400-InvalidParameter, Metadata size is N bytes`.
  user_data and ssh_authorized_keys are immutable after launch (change =
  replace).
- **Image import**: QCOW2 or VMDK (single file), one disk, ≤ 1 TB, not
  encrypted, from an Object Storage bucket. Launch mode PARAVIRTUALIZED
  (kernel ≥ 3.4). Imported images default to **BIOS** firmware; the image
  capability schema (`Compute.Firmware` = `UEFI_64`) switches it. Custom images
  do not support Secure Boot. Images are regional (all ADs of the region).
- **Bare metal**: imported images usually do not boot on BM shapes, which boot
  over iSCSI (needs iSCSI in the initrd). All BM GPU shapes (A100, H100, L40S,
  BM.GPU.A10.4) are out of scope for v1. **v1 targets VM GPU shapes**
  (`VM.GPU.A10.1`, `VM.GPU.A10.2`).

## Step 0: blockers (manual, before any code)

1. Ignition in the Elemental image ≥ 2.22.0 (`rpm -q ignition` in the built
   OS, or the base-os image's package list). If older: stop, open a SUSE
   request, record it in `docs/workarounds.md`.
2. Ignition's oraclecloud provider IMDS endpoint (v1 `/opc/v1/` or v2
   `/opc/v2/`): decides whether nodes can set
   `instance_options.are_legacy_imds_endpoints_disabled = true`.
3. Manual boot test: upload the current exoscale qcow2 (same raw → qcow2
   conversion) to a bucket, `oci compute image import`, set
   `Compute.Firmware=UEFI_64` and PARAVIRTUALIZED via a capability schema,
   launch one `VM.Standard.E5.Flex` with a minimal Ignition in user_data.
   Check: boots, Ignition fetches config, NIC up by DHCP, MTU seen (expect
   9000), console output via serial console history.
4. Same image on `VM.GPU.A10.1`: shape compatible (add an
   `image-shape-compatibility-entry` if needed), GPU visible, precompiled SLES
   16.1 driver loads.
5. Tenancy: GPU service limit per AD (new tenancies start at 0; trial accounts
   cannot get GPUs), NLB limit, a compartment for tests, API key for the user.
   Whether tenancy-level IAM (dynamic groups) is available (not needed by this
   plan, see Image pipeline).

Record results here (date + outcome), then go on.

### Results

- 2026-11-13, 0.1 **pass**: `registry.suse.com/beta/uc/base-os-kernel-default:16.1-73.2`
  ships Ignition **2.26.0** (`version.Raw` in the initrd binary), oraclecloud
  provider compiled in.
- 2026-11-13, 0.2 **pass**: provider reads
  `http://169.254.169.254/opc/v2/instance/metadata/user_data`
  (`Authorization: Bearer Oracle`, retries 429), base64-decodes it, no gzip
  (v2.26.0 `oraclecloud.go`, `util.ParseConfig`). Nodes can disable legacy
  IMDS. Use `compress_node_files = true` (per-file gzip inside Ignition), not
  gzip of the whole user_data.
- 2026-11-13, 0.5 **pass** (test tenancy, home region `eu-frankfurt-1`, 3 ADs;
  `us-ashburn-1` also subscribed). AD-1 offers `VM.GPU.A10.1`,
  `VM.GPU.A10.2`, `VM.Standard.E5.Flex` (plus BM: `BM.GPU.A10.4`,
  `BM.GPU4.8`, `BM.GPU.B4.8`, `BM.Standard.E5.192`, `BM.DenseIO.E5.128`).
  Available in AD-1: `gpu-a10-count` 31 (1 used), `standard-e5-core-count`
  4629, `standard-e5-memory-count` 69444. Regional:
  `max-nlb-flexible-count` 20, `reserved-public-ip-count` 50. These limit
  names (services `compute`, `network-load-balancer-api`, `vcn`) feed
  `availability.tf`. AD names carry a tenancy prefix (`KiWy:EU-FRANKFURT-1-AD-1`).
- Found: `modules/image-factory` installs packages with `zypper`, so the
  jumphost must be SUSE-family, but OCI platform images are Oracle Linux,
  Ubuntu, etc. Options: a `dnf` branch in the factory script (Oracle Linux 9
  platform image; podman + qemu-img available), a SLES Marketplace image, or
  importing an openSUSE Leap cloud qcow2 first. **Decided 2026-11-13: Oracle
  Linux 9 + a `dnf` branch in `modules/image-factory`.**

## Design

### Passes: 1 (like aws)

OCI NLB backends are separate resources (`oci_network_load_balancer_backend`
by instance OCID), so the order is: NLB + reserved public IP → address in the
image config (sslip.io hostnames, tls-san) → image → instances → backends. No
cycle, no second pass. `deploy.sh` still exists with the common interface.
Write ADR (next free number; 011 is taken by `feat/baremetal`) stating this.

### Auth and provider variables (`modules/oci/variables.tf`)

- `oci_tenancy_ocid`, `oci_user_ocid`, `oci_fingerprint`,
  `oci_private_key_path` (or `oci_private_key`, sensitive),
  `oci_compartment_ocid`. Go in `common-oci.tfvars`, never `common-all`.
- `region` = OCI region (`eu-frankfurt-1`). `zones` = AD short names
  (`AD-1`…), resolved to tenancy-prefixed names with
  `oci_identity_availability_domains`. Regions with one AD: spread over fault
  domains instead (`FAULT-DOMAIN-1..3`), round-robin per pool.

### Shapes

Common `*_instance_type` stays a string. Flex shapes take
`<shape>:<ocpus>x<memory_gb>` (e.g. `VM.Standard.E5.Flex:4x32`), parsed in
`locals.tf` into `shape` + `shape_config`; fixed shapes (`VM.GPU.A10.1`) are
the plain name. Validation: flex without the suffix fails at plan. Decide in
the ADR; alternative is a provider-only `shape_configs` map.

### Network (`network.tf`, `firewall.tf`)

- VCN (`vpc_cidr`), public subnet (jumphost, NLB), private subnet (nodes, no
  public IP), internet gateway, NAT gateway (node egress), route tables.
  Regional subnets (span ADs).
- NSGs, not security lists (security list left empty/default deny):
  `jumphost`, `nlb`, `control-plane`, `agent`. Intra-cluster rules from
  `modules/rke2-ports`. NLB health checks: allow from the public subnet CIDR
  on the backend ports (verify source in Step 0/first deploy).
- `admin_cidrs` → jumphost SSH; `api_cidrs` → 6443/9345 listener NSG;
  `ingress_cidrs` → 80/443.
- Single VNIC per VM → `write-node-ip.sh` is a no-op. MTU: VCN 9000
  internally, 1500 to the internet; set `vpc_mtu` default from Step 0 result,
  pod MTU = `vpc_mtu − 50`.
- Existing VCN/subnets (`existing_network` rollout): follow-up PR, same shape
  as aws #58.

### Load balancer (`loadbalancer.tf`)

Network Load Balancer (L4, `is_preserve_source = true`), public, reserved
public IP (`oci_core_public_ip` `RESERVED`) so the address survives NLB
replacement. Listeners: 6443, 9345 (agents join via private NLB address or
the first control plane IP; decide by testing hairpin through NLB with
preserved source), 80, 443. Backends by `target_id`. Hostnames:
`<ip>.sslip.io` (verify in first deploy, like the other three).

### Image pipeline (`build.tf`, `image.tf`)

1. Jumphost (Oracle Linux 9 platform image via `oci_core_images`, latest,
   override `jumphost_image`) builds the raw with the shared factory templates
   (as exoscale; the factory script gains a `dnf` branch), converts to qcow2
   (exoscale's step), uploads.
2. Upload without credentials on the instance: Terraform creates a private
   bucket and a **write-only pre-authenticated request**
   (`oci_objectstorage_preauthrequest`, `ObjectWrite`, short expiry) for the
   image object and a `done` marker; the jumphost `curl -T`s both. No dynamic
   group / instance principal needed. CLAUDE.md security rule: extend the aws
   jumphost exception to "the OCI jumphost uploading the image through a
   write-only PAR".
3. `terraform_data.image_ready` local-exec polls the marker with a read PAR
   + `curl -sfI` (no oci CLI in the deploy path; same role as aws
   `wait-for-raw.sh`).
4. `oci_core_image` from `objectStorageTuple`, `launch_mode = PARAVIRTUALIZED`,
   long create timeout; `oci_core_compute_image_capability_schema` with
   `Compute.Firmware = UEFI_64`; `oci_core_shape_management` for the GPU shapes
   in use.
5. Name and labels carry `build_hash`; rebuild only when it changes. Kernel
   cmdline `console=ttyS0,115200n8 console=tty0 quiet
   ignition.platform.id=oraclecloud` (serial console port to confirm in
   Step 0).
6. `keep_build_artifacts = false`: delete the bucket object (Terraform owns
   the bucket; objects written by PAR need a cleanup step on destroy, e.g.
   bucket `lifecycle_policy` + destroy-time local-exec, decide in ADR).
7. `image_id` skips the chain, as in aws.

### Nodes (`control-plane.tf`, `agent-nodes.tf`)

`oci_core_instance` per node (no pools: per-node user_data, single pass).
`metadata.user_data = base64encode(...)` with `compress_node_files = true`
(the oraclecloud provider does not gunzip user_data). elemental-config `user_data_limit` set so the plan fails
before 32,000 bytes of metadata (budget for ssh key + OCID-length margin,
mirror the aws size preconditions). `preserve_boot_volume = false`.
`control_plane_public_ip` → assign public IP in the public subnet (check
the existing semantics in other providers).

### Labels (`docs/conventions.md#labels`)

`freeform_tags` with the `elemental-*` keys + `role`, `pool`, `build`,
`listener`. OCI tag keys allow `-`, no `.` or spaces: compatible. Apply to
every taggable resource (VCN, subnets, NSGs, NLB, IP, bucket, image,
instances, volumes).

### Quota and availability (`availability.tf`, hard-fail)

- `oci_limits_resource_availability` per AD for each shape family (compute
  core/memory limits for flex families, `gpu-a10-count` style limits for
  GPUs), NLB count, reserved public IPs. Postconditions compare with the
  requested totals.
- `oci_core_shapes` per AD: every requested shape offered in its AD
  (precondition). Capacity can still fail at launch ("Out of host capacity"):
  document, not checkable.
- All through the provider: no signed API script needed.

### Outputs

Identical set (`docs/conventions.md#outputs`); OCIDs, compartment, NLB id,
reserved IP id, bucket in `provider_details`. CI output-consistency check
covers it once the provider is in the matrix.

## Tooling and repo touchpoints

- `modules/oci/variables-common.tf` symlink; `examples/oci/{main,variables,
  outputs,versions}.tf`, `deploy.sh`, `terraform.tfvars.example`, README.
- `examples/oci/tests/*.tftest.hcl` with `mock_provider "oci"`; complete mock
  values (tofu); `make tofu-tests-gen`; `catalog.tftest.hcl` mocked
  availability list.
- `catalog/<NN-shape>/oci/README.md` + tfvars examples (start with 01 and
  the shape using `VM.GPU.A10.1`; shapes needing BM GPUs marked unsupported).
- `scripts/lib/ssh.sh`: jumphost ProxyJump as the others.
- `tools/leftovers/oci.sh`: `oci search resource structured-search` with
  `freeformTags.key = 'elemental-cluster'` (suggested, never run) + test.
- `tools/cost`: OCI public price list API
  (`apexapps.oracle.com/pls/apex/cetools/api/v1/products/`, no auth);
  flex = OCPU-hour + GB-hour; `main_oci_test.go`; `TestDefaultsMatchLocals`.
  Note egress pricing (first 10 TB/month free) in the doc. evroc price
  memory: check whether the API covers all needed SKUs before coding.
- `tools/webui/ui.yaml` `oci:` block (credentials write-only); Dockerfile:
  provider mirror comes from `terraform get` automatically; no oci CLI in the
  image for v1.
- CI: `provider: [aws, evroc, exoscale, oci, vultr]` → new required check
  `validate (oci)`: README "Required checks" `gh api` command (admin).
- Makefile `cost` help, leftovers loop, deploy tests.
- Docs: `docs/providers/oci.md` (same headings as exoscale.md),
  `docs/architecture.md` (network + image pipeline), `docs/conventions.md`
  if any mapping (AD ↔ zone), README provider table, CLAUDE.md provider facts
  (user_data limit, platform id, passes, UEFI capability), ADR,
  `docs/e2e-checklist.md` OCI column.

## Implementation status (PR 2)

- [x] `modules/oci`: VCN, subnets, gateways, NSGs, public NLB on a reserved IP
  (listeners and backend sets, no backends), jumphost on Oracle Linux 9, PAR
  upload, `oci_core_image` + UEFI capability schema + GPU shape management,
  plan-time shape and limit checks, full output set.
- [x] `examples/oci` with `deploy.sh`, `terraform.tfvars.example`, README.
- [x] Mocked tests, tofu variants, CI matrix entry, ADR 012, provider notes.
- [ ] First real deploy: image reaches AVAILABLE and boots (HEAD on PAR, read
  PAR for an absent object, UEFI boot, MTU, NLB health check sources, parallel
  backend set creation, shape management need).
- [ ] Ruleset required check `validate (oci)` (admin).
- [x] Nodes (control planes, GPU and worker agents, fault-domain spread), NLB
  backends (API backend sets without source preservation, NLB NSG), jumphost
  lifecycle (bastion while nodes exist), per-node quota checks, outputs,
  mocked tests, catalog shapes 01 to 05 (VM GPU shapes only; no shape needs bare
  metal) and the end-to-end runbook (PR 3).
- [ ] Cost estimate, leftovers, webui (PRs 4 and 5).

## PR sequence

Each PR passes the 16 required checks; titles Conventional Commits.

1. `docs(oci): ADR and provider plan` — this file's decisions as the ADR,
   after Step 0.
2. `feat(oci): network, jumphost and image pipeline` — `deploy_nodes = false`
   path works end to end (image ends `AVAILABLE`, boots in a manual test).
3. `feat(oci): control plane, agents and NLB` — full cluster, outputs,
   quota/availability checks, tests, CI matrix + ruleset check.
4. `feat(cost): oci estimate`.
5. `feat(oci): leftovers, catalog plans, webui`.
6. Follow-ups: existing VCN/subnets, BM GPU shapes (iSCSI boot), private
   NLB for agent join, e2e checklist.

User runs every deploy; each PR lists the commands and checks.

## Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Elemental Ignition < 2.22 | Blocks provider | Step 0.1; SUSE request |
| Imported UEFI image does not boot | Blocks provider | Step 0.3; capability schema |
| 32,000-byte metadata limit | Large Ignition fails at launch | gzip, plan-time precondition with margin |
| GPU limits 0 / host capacity | Cannot test GPUs | Request limit early; A10 VM shapes |
| BM GPU shapes need iSCSI boot | No large GPU nodes in v1 | Out of scope, follow-up |
| NLB hairpin with preserved source | Agent join through NLB fails | Test; join via private address |

## Sources

- [Ignition supported platforms](https://coreos.github.io/ignition/supported-platforms/)
- [Ignition release notes](https://github.com/coreos/ignition/blob/main/docs/release-notes.md) (2.22.0)
- [Importing custom Linux images](https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/importingcustomimagelinux.htm)
- [Image capabilities for custom images](https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/configuringimagecapabilities.htm)
- [External custom images on bare metal](https://blogs.oracle.com/cloud-infrastructure/enabling-external-custom-images-virtual-and-bare-metal)
- [oci_core_instance metadata limit](https://registry.terraform.io/providers/oracle/oci/5.42.0/docs/resources/core_instance)
- [Compute shapes](https://docs.oracle.com/en-us/iaas/Content/Compute/References/computeshapes.htm)
