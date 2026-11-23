# Plan: Microsoft Azure provider

Status: implemented (`modules/azure`, `examples/azure`, 2026-11-23), untested
against a real subscription. Step 0 pending (account access), results go below;
see [ADR 015](../decisions/015-azure-module.md) and
[docs/providers/azure.md](../providers/azure.md). Research from 2026-11-20;
"Implementation decisions" at the end are binding for the first implementation.

Goal: `modules/azure` + `examples/azure` at parity with the other providers:
same common variables, outputs, labels, `deploy.sh` interface, plan-time
quota/availability hard-fails, cost estimate, leftovers script, catalog plans,
CI job, webui entry.

## Naming

Directory and identifier: **`azure`** (Terraform providers
`hashicorp/azurerm` + `azure/azapi`, CLI `az`). Docs title: "Microsoft Azure".

## Facts checked (2026-11-20, web only, nothing tested)

- **Ignition**: platform id `azure`. Provider reads IMDS
  `http://169.254.169.254/metadata/instance/compute/userData?api-version=2021-01-01&format=text`
  (`Metadata: true`), base64-decodes it; falls back to `customData` on the
  provisioning CD-ROM (UDF) only when userData is empty. IMDS userData since
  Ignition **2.14.0**; the beta base-os image ships **2.26.0** (OCI Step 0), so
  supported. Using `user_data` (not `custom_data`) avoids UDF/sr_mod in the
  initrd. Source: `coreos/ignition` `internal/providers/azure/azure.go`.
- **Report ready**: a generalized-image VM without an agent must POST a health
  "Ready" to WireServer `168.63.129.16`, or Azure reboots it after ~20 min and
  fails provisioning (`OSProvisioningTimedOut`, ~40 min). Microsoft documents a
  curl-only version ("Creating generalized images without a provisioning
  agent"): GET `/machine/?comp=goalstate` (`x-ms-version: 2012-11-30`), parse
  `ContainerId`/`InstanceId`/`Incarnation`, POST `/machine?comp=health`.
  Fits the repo pattern: script written by Ignition + systemd oneshot, `grep`/
  `sed`, no Python. VM: `provision_vm_agent = false`,
  `allow_extension_operations = false`. Specialized images skip osProfile but
  azurerm support for them is poor (`terraform-provider-azurerm#22968`):
  stay generalized.
- **Initrd modules**: `hv_vmbus hv_storvsc hv_netvsc` (boot disk + NIC), `nvme
  nvme_core` (NVMe sizes), `mana` + `mlx5_core` (accelerated networking; v6
  sizes are MANA). Ignition's dracut module only adds `hv_utils`.
- **user_data limit**: 64 KB documented; customData error says 87,380 base64
  chars (65,535 decoded). Unclear for userData whether before or after base64:
  assume after → `user_data_max_bytes` ≈ 48,000 raw. No gzip needed (budget is
  2× OCI).
- **Image import**: fixed VHD, virtual size multiple of 1 MiB, ≤ 1,023 GB,
  stored as a **page blob** (`qemu-img resize` up to 1 MiB, then
  `qemu-img convert -f raw -O vpc -o subformat=fixed,force_size`). Then an
  **Azure Compute Gallery** image: `azurerm_shared_image`
  (`hyper_v_generation = "V2"`, default V1!, `disk_controller_type_nvme_enabled`)
  + `azurerm_shared_image_version` (`blob_uri` + `storage_account_id`).
  Managed images (`azurerm_image`) are "legacy", cannot be NVMe-tagged or
  Trusted Launch: skip them. Copy Blob from an arbitrary HTTP URL to a page blob
  is not documented, so the jumphost uploads.
- **Security type**: request `Standard` (no Trusted Launch / Secure Boot).
  Secure Boot needs a signed shim/kernel and the NVIDIA driver on non-Ubuntu
  Linux expects it off.
- **GPU sizes (candidates)**: `Standard_NC4as_T4_v3` (cheap test),
  `Standard_NV36ads_A10_v5`, `Standard_NC24ads_A100_v4`,
  `Standard_NC40ads_H100_v5`, `Standard_ND96isr_H100_v5`/`H200_v5`,
  `Standard_NC*_xl_RTXPRO6000BSE_v6` (GA 2026-06, fractional sizes probably
  need vGPU/GRID: out of scope). `ND GB200 v6` is **arm64**: out of scope. New
  subscriptions have **0 vCPU** GPU family quota per region; requests are
  manual. Gen/controller per older series: check in Step 0.
- **Networking**: subnets created with recent API versions have
  `defaultOutboundAccess = false` → **NAT gateway** for private nodes. Standard
  public LB does not SNAT inbound (client IP preserved). Health probes come from
  `168.63.129.16` (`AzureLoadBalancer` service tag). **No hairpin**: a backend
  VM reaching the LB frontend it sits behind fails or works intermittently;
  workaround is floating IP (DSR) + frontend IP on loopback. VNet MTU 1500
  default (up to 3900/9000 in-VNet).
- **Tags**: ≤ 50/resource, key ≤ 512 (128 on storage accounts), value ≤ 256,
  keys exclude `< > % & \ ? /`: `elemental-*` keys fit.
- **Naming exceptions**: storage account 3–24 lowercase alnum, globally unique
  (no hyphens); gallery name no hyphens (`_`/`.` allowed). Needs a documented
  exception in `docs/conventions.md#naming` (e.g. `<cluster>_gallery`,
  `aif<hash8>` storage account).
- **Auth**: azurerm **5.x** (5.14.0). `subscription_id` mandatory; CLI auth
  (`az login`) or service principal (`ARM_TENANT_ID`, `ARM_CLIENT_ID`,
  `ARM_CLIENT_SECRET`). 5.0 defaults `resource_provider_registrations = "none"`:
  Compute/Network/Storage must be registered or listed in
  `resource_providers_to_register`.
- **Plan-time checks**: no azurerm SKU/quota data source (PR #28382 open). Use
  azapi: `Microsoft.Compute/skus` (`restrictions[]`, `locationInfo.zones`,
  `NotAvailableForSubscription`) and
  `Microsoft.Compute/locations/{loc}/usages` (per-family vCPU `limit`/
  `currentValue`, plus `PublicIPAddresses`, LB counts from Network usages).
  Exact azapi syntax (`azapi_resource_list` vs `azapi_resource_action` GET):
  untested.
- **Serial log**: managed boot diagnostics (`boot_diagnostics {}`);
  `retrieveBootDiagnosticsData` returns a SAS URI of the serial log. Kernel
  cmdline `console=ttyS0`. Refresh rate unknown: decides whether the build
  progress needs an evroc-style relay or the serial log is enough.
- **Prices**: Retail Prices API `https://prices.azure.com/api/retail/prices`,
  no auth, OData `$filter` on `armRegionName`/`armSkuName`/`priceType`,
  `currencyCode`, paged (`NextPageLink`). Filter out Windows/Spot/Low Priority.
- **Jumphost image** (SUSE pint): `SUSE:sles-16-0-x86-64:gen2:latest` (PAYG)
  or `susellc:opensuse-leap-x86-64:gen2:latest` (Leap 16.1). zypper → the
  image factory works unchanged. Marketplace plan acceptance: unverified.

## Step 0: blockers (manual, once the account is ready)

1. Subscription: register `Microsoft.Compute`, `Microsoft.Network`,
   `Microsoft.Storage`; request GPU quota (NCasT4_v3 first) in the test region;
   pick a region with 3 zones and the GPU SKU. Record SKU/zone restrictions.
2. Storage account shared-key access allowed (SAS needs it; some org policies
   disable it → would need user delegation SAS or a managed identity).
3. Manual boot test: current raw image → fixed VHD → page blob (azcopy) →
   gallery image V2 (confirm `az vm show --query securityProfile` reports
   `Standard`) → `az vm create` (D-series,
   `--enable-agent false`, `--user-data` minimal Ignition with the report-ready
   unit). Check: boots (hv_storvsc in initrd), Ignition reads userData, VM
   reaches `Succeeded` (report ready works), NIC/DHCP, MTU, serial log content
   and refresh.
4. Same image on an NVMe-only size (v6) with the NVMe flag; same image on
   `Standard_NC4as_T4_v3`: GPU visible, precompiled SLES 16.1 driver loads,
   accelerated networking VF (mlx5/MANA) not grabbed by NetworkManager.
5. userData size: launch with ~60 KiB raw (fails?) and ~47 KiB raw (passes) to
   settle before/after base64.
6. LB hairpin: with the `azure-lb-hairpin` timer disabled first, measure a
   control plane reaching `<frontend>:9345/6443/443` (the NAT gateway may SNAT
   control-plane flows to the public frontend, so the hairpin may not occur at
   all), then with the chosen fix (see Load balancer; 6443 and 9345 only).
   Ingress hairpin from control planes stays open: the nft DNAT to the node IP
   pre-empts the CNI hostPort DNAT (Traefik would get a reset), so 80 and 443
   are not redirected. Check 443 from a pod on a control plane.
7. Jumphost image plan requirement: `az vm image show --urn ...` (`plan` null?).

Record results here (date + outcome), then go on.

## Design

### Passes: 1 (like aws, oci)

Static Standard public IP and LB exist before the image (address in the image:
apiVIP, sslip.io hostnames, tls-san). Backend pool membership is a separate
resource per NIC (`azurerm_network_interface_backend_address_pool_association`).
NIC private IPs can be static and known at plan. No cycle.

### Resource group

One resource group per cluster (`<cluster>`), created by the module unless
`resource_group_name` is given. Destroy and leftovers become simple
(`az resource list -g` / tag search).

### Auth and provider variables

`azure_subscription_id`, optional `azure_tenant_id`, `azure_client_id`,
`azure_client_secret` (sensitive; else CLI auth). In `common-azure.tfvars`,
never `common-all`. `region` = location (`westeurope`); `zones` = `["1","2","3"]`
(empty for zoneless regions → no zone pinning).

### Network (`network.tf`, `firewall.tf`)

VNet (`vpc_cidr`), public subnet (jumphost, LB), private subnet (nodes, no
public IP, `default_outbound_access_enabled = false`), NAT gateway + static
public IP on the private subnet. NSGs per role (`jumphost`, `control-plane`,
`agent`), rules from `modules/rke2-ports`; `admin_cidrs` → jumphost 22,
`api_cidrs` → 6443/9345, `ingress_cidrs` → 80/443, allow `AzureLoadBalancer`
on probe ports. Single NIC → `write-node-ip.sh` no-op. `vpc_mtu` default 1500
(check Step 0), pod MTU = `vpc_mtu − 50`. Existing VNet (`vpc_id` + subnet
ids): follow-up PR.

### Load balancer (`loadbalancer.tf`)

Standard public LB, static zone-redundant public IP, rules 6443, 9345, 80, 443
to control planes, TCP probes. Hostnames `<ip>.sslip.io` (verify).

How the others handle apiVIP (`network.apiVIP`, `apiVIPMode: external`;
elemental derives the join URL `https://<apiVIP>:9345` from it):

| Provider | apiVIP | Hairpin handling |
|---|---|---|
| aws | static private IP of an internal NLB (`cidrhost(private subnet 0, 10)`), separate public NLB for kubectl/ingress | `preserve_client_ip = false` (NLB SNATs) |
| oci | reserved public IP of the NLB | `is_preserve_source = false` (ADR 012) |
| vultr, evroc | managed LB public IP | proxy LBs, source is the LB |
| exoscale | NLB IP, direct return, client IP kept | works as is (e2e passed) |

Every control plane is a client of the LB it backs: joins (9345), API
(6443), and in-cluster clients of the Rancher/ingress hostnames (443).
Azure Standard LB never SNATs inbound and has no toggle for it, so a flow
from a control plane hashed to itself drops. Joins mostly survive (a joining
node fails its probe, so the LB does not pick it), but steady-state traffic
from healthy control planes fails ~1/N of the time.

Prior art outside this repo (2026-11-20):

- **OpenShift IPI** (`machine-config-operator`,
  `templates/master/00-master/azure/files/opt-libexec-openshift-azure-routes-sh.yaml`):
  nft table `inet azure-vips`, `ip daddr { VIPs } redirect` in `prerouting` +
  `output` (dstnat). **Gated on local apiserver health**: a watcher static pod
  writes `/run/cloud-routes/<VIP>.up|.down`, a `.path` unit reruns the script,
  a 30 s timer covers the first 15 min (MCO PRs 3643, 3904, 5455).
- **CAPZ**: public template does nothing; private (ILB) template adds
  `127.0.0.1 apiserver.<cluster>.capz.io` to `/etc/hosts` on control planes
  (needs a hostname endpoint, not a baked IP). Known issue: single control
  plane hairpins.
- **rancherfederal/rke2-azure-tf**: Standard LB 6443/9345, TCP probe 6443, no
  floating IP, `server: https://<lb>:9345` on non-leaders, **no workaround**.
  Works mostly because a joining server fails the probe and RKE2 uses
  127.0.0.1 / its client-side LB to server private IPs after join.
- **Talos** (KubePrism, localhost LB) and **Kubespray** (local proxy): the
  endpoint is only for bootstrap.
- **aks-engine**: iptables `REDIRECT` in PREROUTING only; broke ~1/3 of calls
  from pods on masters (Azure/aks-engine#622).
- **Microsoft**: hairpin unsupported by design, no flag. Fixes: connect to the
  private IP, a proxy, second NIC + route, floating IP + VIP on `lo`
  (`microsoft/Azure-ILB-hairpin`, load-balancer-floating-ip doc; no arp
  sysctls mentioned, weak host model default).

Who hits it: only LB backends (control planes); agents are fine. A joining
server is protected by the probe. Remaining: restarts/re-joins dialing the
VIP, tools on control planes, and pods on control planes reaching the
Rancher/ingress hostnames (Rancher's own cattle-cluster-agent).

Options:

- **A (lean, OpenShift pattern)**: health-gated nft on control planes:
  `ip daddr <VIP> tcp dport {6443,9345}` → `dnat to <own private IP>`
  in `output` (node processes) and `prerouting` (pods), added only when the
  local service answers, removed when it stops. No floating IP, LB config
  unchanged, VIP known at plan (oneshot + `.path`/timer in the image). DNAT
  to the private IP rather than `redirect` (→ 127.0.0.1 in `output`, which
  needs `route_localnet` for hostPort DNAT).
- B (Microsoft pattern): floating IP + VIP on `lo`. Must be gated too: an
  ungated `lo` VIP makes a joining server dial itself on 9345 and fail.
  Frontend port = backend port (true here), probes still hit the NIC IP,
  outbound must use the primary IP.
- C (rke2-azure-tf): nothing; accept intermittent failures. Baseline to
  measure in Step 0.6.
- D: apiVIP = first control plane private IP for joins. Leaves ingress
  hairpin, joins depend on node 0.

Settle in Step 0.6: measure C, then A.

### Image pipeline (`build.tf`, `image.tf`)

1. Jumphost (SLES 16 / Leap 16 marketplace, `jumphost_image` override, waagent
   present) builds the raw with the shared factory templates (zypper, no
   change), converts to fixed VHD.
2. Upload without credentials on the instance: Terraform creates a storage
   account + private container and a **write-only container SAS**
   (`data.azurerm_storage_account_blob_container_sas`, create+write, short
   expiry). Jumphost uploads the page blob and a `done` marker. Uploader: pinned
   `azcopy` (sha256) or a curl `Put Page` loop (4 MiB chunks, skip zero
   chunks); decide in ADR. Extend the CLAUDE.md security exception to "the
   azure jumphost uploading the VHD through a write-only SAS".
3. `terraform_data.image_ready` polls the marker with a read SAS (`curl -sfI`),
   as oci.
4. `azurerm_shared_image` (V2, NVMe+SCSI, `Standard`) + `azurerm_shared_image_version`
   named from `build_hash` (versions must be `N.N.N`: derive from the rebuild
   counter or a hash-to-int), long create timeout.
5. Kernel cmdline `console=ttyS0,115200n8 console=tty0 quiet
   ignition.platform.id=azure`.
6. `keep_build_artifacts = false`: delete the blob (storage account owned by
   Terraform; blob written outside Terraform needs a destroy-time step or
   lifecycle rule, as oci).
7. `image_id` (gallery image version id) skips the chain.

### Nodes

`azurerm_linux_virtual_machine` per node (no VMSS: per-node user_data, single
pass). `user_data = base64encode(ignition)`, `provision_vm_agent = false`,
`allow_extension_operations = false`, dummy `admin_username` + the first SSH
key (required by the resource, ignored by the image), `boot_diagnostics {}`,
`security_type` Standard, `disk_controller_type` per size, zone round-robin.
Elemental config adds `azure-report-ready.sh` + unit (new elemental-config
toggle, off for other providers). `control_plane_public_ip` → public IP on the
NIC (or reject like oci; decide).

### Labels

Azure tags with `elemental-*` keys + `role`, `pool`, `build`, `listener` on
every taggable resource. Tag search covers leftovers.

### Quota and availability (`availability.tf`, hard-fail)

azapi reads of SKUs (offered in region/zone, not restricted for the
subscription, Gen2 + NVMe capability) and usages (family vCPUs, total regional
vCPUs, public IPs). Postconditions compare with requested totals. Capacity
errors at create (`AllocationFailed`, `ZonalAllocationFailed`) are not
checkable: document.

### Outputs

Identical set; resource group, VNet, LB, gallery image version, storage account
in `provider_details`.

## Repo touchpoints

- `modules/azure/variables-common.tf` symlink; `examples/azure/*`, `deploy.sh`,
  tfvars example, README; tests with `mock_provider "azurerm"` + `"azapi"`,
  `make tofu-tests-gen`.
- `modules/elemental-config`: report-ready script/unit toggle; feeds `build_hash`
  only if it is in the image (it is node user_data, so no).
- `modules/image-factory`: VHD conversion step (provider-side template, as
  exoscale's qcow2 step).
- `catalog/<NN>/azure/` + `catalog.tftest.hcl` availability mocks.
- `tools/leftovers/azure.sh` (`az resource list --tag elemental-cluster=<c>`) +
  test; Makefile loop.
- `tools/cost`: Retail Prices API; `main_azure_test.go`;
  `TestDefaultsMatchLocals`. Managed disk price by tier (P/E SSD), LB rules,
  NAT gateway hours + data, public IPs.
- `tools/webui/ui.yaml` `azure:` block; service principal env vars (no `az` CLI
  in the image for v1).
- CI matrix `azure` → required check `validate (azure)` (18 checks; admin
  `gh api` in README).
- `scripts/build-logs.sh`: serial log via `az vm boot-diagnostics get-boot-log`
  if the relay is not needed.
- Docs: ADR (next free number after harvester), `docs/providers/azure.md`,
  `docs/architecture.md`, `docs/conventions.md` (naming exceptions, zone
  mapping), README table, CLAUDE.md provider facts, `docs/e2e-checklist.md`.

## Open questions

- Hairpin fix (A/B).
- azcopy vs curl uploader.
- Gallery version numbering from `build_hash`.
- Serial log refresh vs status relay.
- Whether SLE 16 ships `afterburn` (would replace the curl report-ready).

## Sources

- https://github.com/coreos/ignition/blob/main/internal/providers/azure/azure.go
- https://github.com/coreos/ignition/blob/main/docs/release-notes.md
- https://learn.microsoft.com/en-us/azure/virtual-machines/linux/no-agent
- https://learn.microsoft.com/en-us/troubleshoot/azure/virtual-machines/linux/linux-custom-image-provisioning-errors
- https://learn.microsoft.com/en-us/azure/virtual-machines/linux/create-upload-generic
- https://learn.microsoft.com/en-us/azure/virtual-machines/migration/migration-managed-image-to-compute-gallery
- https://learn.microsoft.com/en-us/azure/virtual-machines/trusted-launch
- https://learn.microsoft.com/en-us/azure/virtual-machines/nvme-overview
- https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/gpu-accelerated/nc-rtxpro6000-bse-v6-series
- https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-mana-existing-sizes
- https://learn.microsoft.com/en-us/azure/virtual-network/ip-services/default-outbound-access
- https://learn.microsoft.com/en-us/azure/load-balancer/load-balancer-floating-ip
- https://learn.microsoft.com/en-us/troubleshoot/azure/load-balancer/troubleshoot-load-balancer-platform-limitations
- https://learn.microsoft.com/en-us/azure/virtual-machines/user-data
- https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/resource-name-rules
- https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices
- https://learn.microsoft.com/en-us/rest/api/compute/resource-skus/list
- https://learn.microsoft.com/en-us/rest/api/compute/usage/list
- https://github.com/hashicorp/terraform-provider-azurerm/blob/main/website/docs/guides/5.0-upgrade-guide.html.markdown

## Implementation decisions (2026-11-23, before Step 0)

Binding for the first implementation; Step 0 may revise them.

- **ADR 015** (`docs/decisions/015-azure-module.md`; 011–014 are taken on
  other branches). Single pass, like oci.
- **Defaults (`modules/azure/locals.tf`, mirrored by `tools/cost`)**: region
  `westeurope`; `vpc_cidr` `10.20.0.0/20` (public subnet low half, private
  high half); `vpc_mtu` 1500, pod MTU `vpc_mtu − 50`; control plane
  `Standard_D8s_v5`, 100 GB; agent disk 200 GB; jumphost `Standard_D4s_v5`,
  100 GB; OS disks `Premium_LRS`; jumphost image
  `SUSE:sles-16-0-x86-64:gen2:latest` (`jumphost_image` takes a
  `publisher:offer:sku:version` URN).
- **Provider variables**: `azure_subscription_id` (required),
  `azure_tenant_id`, `azure_client_id`, `azure_client_secret` (sensitive,
  optional: CLI auth otherwise), `resource_group_name` (existing group;
  null = module creates `<cluster>`). azurerm 5.x + azapi 2.x;
  `resource_provider_registrations = "none"` plus
  `resource_providers_to_register = [Compute, Network, Storage]`.
- **Existing network**: `vpc_id` (VNet resource ID), `public_subnet_id`,
  `private_subnet_id` (subnet resource IDs), same semantics as oci (vpc_cidr
  null → first address space; private subnet must have outbound, NAT gateway
  egress IP when attached). NSGs go on NICs, never on user subnets.
- **Security**: NSG per role on NICs (`jumphost`, `control-plane`, `agent`),
  rules from `modules/rke2-ports`, `AzureLoadBalancer` tag on probe ports.
  `control_plane_public_ip` and pool `public_ip` rejected (nodes private).
- **Load balancer**: Standard public LB, static zone-redundant public IP
  (apiVIP), rules 6443/9345/80/443 → control planes, TCP probe 6443 for API
  and supervisor, HTTP `/ping` 8080 for Traefik, `floating_ip = false`,
  `disable_outbound_snat = true`. NAT gateway with static public IP for the
  private subnet.
- **Hairpin**: option A. Script + timer baked in the image
  (`extra_butane_files`/`extra_butane_units`), active only on control planes
  (role from `/var/lib/elemental/runtime.env`): nft table, `ip daddr <VIP>
  tcp dport {6443,9345}` → `dnat to <own private IP>` in `output` and
  `prerouting`, present only while local 6443 answers; same for 80/443 gated
  on local 443.
- **Report ready**: curl-only WireServer health report (Microsoft no-agent
  doc), script + oneshot in the image, all nodes, retries until accepted.
- **Ignition**: `user_data` (IMDS), kernel cmdline
  `console=ttyS0,115200n8 console=tty0 quiet ignition.platform.id=azure`,
  `user_data_max_bytes` 46000, no per-file gzip unless needed.
- **Image**: jumphost (SLES, cloud-init `custom_data`) builds raw → fixed VHD
  (1 MiB aligned) → page blob via a **curl Put Page loop** (4 MiB chunks,
  zero chunks skipped, parallel) with a write-only container SAS; `done`
  marker; operator-side wait polls the marker with a read SAS (curl -sfI).
  SAS expiry anchored to a `time_static` keyed on `build_hash` (an expiry from
  `timestamp()` would replace the jumphost every plan). Storage account
  `aif<12 hex of sha1(subscription/cluster)>`, container `images`.
  Gallery `<cluster with _>_gallery`, image definition `<cluster>-elemental`
  (Linux, Generalized, V2, NVMe+SCSI, Standard security), version
  `1.0.<int of build_hash[0:7]>` from `blob_uri`. `image_id` skips the chain.
  `keep_build_artifacts = false` deletes the blob after the version exists.
- **Nodes**: `azurerm_linux_virtual_machine` per node, `user_data`,
  `provision_vm_agent = false`, `allow_extension_operations = false`,
  `admin_username` = `node_username` + first SSH key (ignored by the image),
  `boot_diagnostics {}`, zone round-robin over `zones`, NVMe controller for
  `_v6` sizes, `replace_triggered_by` the image version.
- **Plan-time checks**: azapi reads of `Microsoft.Compute/skus` (offered,
  not restricted for subscription/zone, HyperVGenerations V2) and
  `Microsoft.Compute/locations/{loc}/usages` (family + regional vCPUs),
  `Microsoft.Network/locations/{loc}/usages` (public IPs); postconditions.
