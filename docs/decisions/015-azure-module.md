# 015 - azure module design

## Status
Accepted. Implemented in `modules/azure`; untested against a real subscription.
The Step 0 checks in the [plan](../plans/azure.md) can still revise it
([platform notes](../providers/azure.md)).

## Context
Platform behaviour that shapes the module (researched in the
[plan](../plans/azure.md); provider `hashicorp/azurerm` 5.x and `azure/azapi`
2.x):

- A Standard public load balancer takes a static public IP, and backend pool
  membership is a separate resource per NIC. The address the image needs
  (apiVIP, hostnames) therefore exists before any VM.
- A VM created from a generalized image without the Azure agent must report
  "Ready" to the WireServer (`168.63.129.16`), or the platform reboots it
  after about 20 minutes and fails the provisioning (`OSProvisioningTimedOut`).
  Microsoft documents a curl-only report for this case.
- Ignition's `azure` platform reads `userData` from the instance metadata
  service (Ignition 2.14 or later; the image ships 2.26). User data is limited
  to 64 KB.
- Custom images are imported from a fixed VHD stored as a page blob (virtual
  size a multiple of 1 MiB). An Azure Compute Gallery image definition is the
  only route to Generation 2 with NVMe support; a managed image cannot carry
  either. Copy Blob from an arbitrary HTTP URL into a page blob is not
  documented, so the build host uploads.
- A container SAS grants rights on a container through a URL, without
  credentials. `create` and `write` allow a blob to be created and its pages
  written, nothing else.
- A Standard load balancer does not rewrite the client address, and a backend
  VM that connects to the frontend it sits behind is not served reliably (the
  flow can be hashed back to the sender). There is no setting for it.
- New subnets have no default outbound access: private nodes need a NAT
  gateway.
- Storage account names are 3 to 24 lowercase letters and digits, unique
  worldwide; Compute Gallery names allow no hyphens.
- azurerm has no data source for VM sizes or quota. Both are ARM reads.

## Decision
- **One pass.** The load balancer and its static IP, then the image, then the
  VMs, then the backend pool membership: no cycle, so `deploy.sh` is single
  pass.
- **Image pipeline.** The jumphost (marketplace SLES 16, cloud-init
  `custom_data`) builds the raw image with podman and converts it to a fixed
  VHD (`qemu-img resize` to 1 MiB, then `convert -O vpc -o subformat=fixed,force_size`).
  It uploads the VHD as a page blob with a `curl` loop through a write-only
  container SAS: create the blob at full size, then `Put Page` 4 MiB chunks in
  parallel, skipping chunks that are all zeros, and finally a `done` marker.
  The jumphost holds no Azure credential. Terraform polls the marker with a
  read SAS (`curl -sfI`), creates the gallery, a Generation 2 image definition
  (SCSI and NVMe, security type Standard, `trusted_launch_supported = false`)
  and a version from
  the blob, then deletes the VHD with a delete SAS. A pinned `azcopy` was not
  chosen: the loop needs only `curl`, which the jumphost image ships, and keeps
  the "no CLI in the deploy path" property.
- **SAS lifetime.** Start and expiry are `time_offset` resources keyed to
  `build_hash` (start 15 minutes back for clock skew, expiry after 6 hours: the build
  timeout is 90 minutes, plus a margin). An upload that outlives the token
  fails with HTTP 403; `deploy.sh --rebuild` creates a new one.
  An expiry computed from `timestamp()` would change the jumphost's
  `custom_data` and replace it on every plan. The jumphost has
  `ignore_changes = [custom_data]`; a new build replaces it through
  `build_trigger`.
- **Gallery names.** The storage account is
  `aif<12 hex of sha1(subscription/cluster_name)>`, stable per subscription and
  cluster; the gallery is `<cluster_name with _>_gallery`; the definition is
  `<cluster_name>-elemental`; the version is `1.0.<integer of the first 7 hex
  digits of build_hash>` (versions are `N.N.N`).
- **Security type Standard.** Secure Boot needs a signed shim and kernel, and
  the NVIDIA driver on this OS expects it off. The node VMs state
  `secure_boot_enabled = false` and `vtpm_enabled = false`, and the image
  definition is not Trusted Launch capable, so no default turns it on.
- **Report ready.** `azure-report-ready.sh` and a oneshot unit are baked into the
  image for every node: it reads the goal state
  (`/machine/?comp=goalstate`, `x-ms-version: 2012-11-30`), then POSTs the health
  document to `/machine?comp=health`, retrying until accepted (`curl`
  and `sed` only; 60 tries 15 seconds apart, about 15 minutes, inside the
  unit's `TimeoutStartSec=16min`). The VMs set `provision_vm_agent = false` and
  `allow_extension_operations = false`. A failed report does not fail the unit:
  the node works and only the platform's provisioning state stays open.
- **Load balancer hairpin: health-gated DNAT on control planes (option A).**
  Control planes reach the API and supervisor through the load balancer
  address (the image has a single address), so each is a client of the
  balancer it backs; so are in-cluster clients of the Rancher hostname.
  `azure-lb-hairpin.sh` (baked in, run by a timer every 15 seconds, control
  planes only) keeps an nft table with `ip daddr <frontend> tcp dport {...}
  dnat to <own private IP>` in the `output` chain (host processes) and
  `prerouting` (pods). The rules exist only while the local 6443 answers: a
  joining node must not dial itself, so the gate also covers the first boot.
  The script does not trust its state file alone: it also checks that the nft
  table exists before it skips a run. DNAT to the private IP rather than
  `redirect`: in `output`, `redirect` goes to 127.0.0.1, which needs
  `route_localnet` for hostPort traffic. The load balancer keeps
  `floating_ip_enabled = false` and the NSGs filter the clients.
  Only 6443 and 9345 are redirected. Ingress (80, 443) is not: the DNAT to the
  node IP runs before the CNI's hostPort DNAT, so Traefik would receive a
  connection it does not listen for and answer with a reset. A pod on a control
  plane that reaches the Rancher hostname through the frontend is an open
  Step 0.6 item. Control-plane traffic to the public frontend may also leave
  through the NAT gateway and come back from its address (the NSGs admit it),
  so the hairpin may not occur at all: Step 0.6 measures with the unit
  disabled first.
  Prior art, all outside this repository:
  - OpenShift on Azure (`machine-config-operator`,
    `opt-libexec-openshift-azure-routes-sh`) redirects the API VIPs in an nft
    table on the masters, gated on a local health file written by a watcher.
  - Cluster API Provider Azure maps the API hostname to `127.0.0.1` in
    `/etc/hosts` on control planes of private clusters; that needs a
    hostname endpoint, not an address baked into the image.
  - `rancherfederal/rke2-azure-tf` runs RKE2 behind a Standard load balancer
    without a workaround; it relies on a joining server failing the probe and
    on the client-side load balancer after the join.
  - Microsoft documents floating IP with the frontend address on the
    loopback (`microsoft/Azure-ILB-hairpin`, "Azure Load Balancer Floating
    IP configuration"). That makes the loopback address answer before the local
    service does, so it needs the same health gate, and it needs the
    frontend port to equal the backend port.
  - aks-engine used an ungated `REDIRECT` in `PREROUTING` only; connections
    from pods on masters still failed intermittently
    ([Azure/aks-engine#622](https://github.com/Azure/aks-engine/issues/622)).
  Floating IP was not chosen because it changes the load balancer and the
  host model for every rule; the DNAT is one script and no balancer change.
  Doing nothing is the baseline Step 0 measures; a private address for
  in-cluster use would need a second join address in `elemental-config`; not
  done.
- **Existing network.** `vpc_id`, `public_subnet_id` and `private_subnet_id`
  (resource IDs, all three or none). `vpc_cidr` null takes the first address
  space. The private subnet must be attached to a NAT gateway with at least one
  public IP address or prefix (read through azapi); all of them are egress IPs
  (`egress_ips`) and clients in the NSG rules. A subnet without a NAT gateway fails the plan. The module adds no
  rule, route table or gateway to the subnets.
- **NSGs on the NICs, never on subnets.** An existing subnet is not touched.
  The platform's default inbound rules allow everything inside the virtual
  network, so each group ends with a deny-all rule at priority 4096 and the
  allowed flows come before it: sources are CIDRs, the `AzureLoadBalancer`
  service tag (probes) or application security groups (`control-plane`,
  `agent`) for node-to-node traffic. `api_cidrs` and `ingress_cidrs` filter on
  the control-plane NSG (the client address is kept); the NAT addresses are
  admitted on every listener for the nodes.
- **Nodes.** One `azurerm_linux_virtual_machine` per node (no scale set:
  per-node user data), in the private subnet with no public IP
  (`control_plane_public_ip` and pool `public_ip` are rejected, as are
  `placement` and bare metal). `user_data` carries the Ignition; the VM
  resource requires an admin account, so `node_username` and the first SSH
  key are passed and ignored by the image. Each VM waits for the NSG, application
  security group and backend pool associations of its NIC, so the first boot
  and the first probe see the final rules. Zone round-robin; NVMe controller
  for `_v6` sizes and sizes that offer NVMe only. `replace_triggered_by` the
  image: a new image replaces every node.
- **Zones.** `zones` are `"1"`, `"2"` and `"3"`; the default is the region's
  logical zones from the subscription's `locations` list
  (`availabilityZoneMappings`), not the per-size restrictions, which change
  over time and would move nodes between plans. A size that is restricted or
  not offered in a zone a node lands in fails the plan. A region without zones
  gives none and nothing is pinned. The public IPs (load balancer, NAT gateway,
  jumphost) set no zones and ignore changes to them: a Standard address is
  zone-redundant by default in a region with zones, so the API address never
  depends on the control-plane size.
- **Jumphost lifecycle.** It exists while the image is built and whenever
  nodes are deployed (the only SSH entry). With `image_id` it builds nothing.
- **Plan-time checks through azapi.** `Microsoft.Compute/skus` for the sizes
  in use (offered in the region and zone, not restricted for the subscription,
  Generation 2, Premium SSD, controller types, accelerated networking, vCPU
  count), the Compute usages (per family and regional vCPUs) and the Network
  usages (Standard public IPs, Standard load balancers). What the cluster
  already holds (VMs, Standard public IPs and load balancers tagged
  `elemental-cluster`) is subtracted. They are
  preconditions on `terraform_data.limits_check`, which every quota-consuming
  resource depends on.
- **Naming exceptions** (see [conventions](../conventions.md#naming)): the
  storage account has no hyphens and the gallery uses `_`; `zones` are numbers;
  `jumphost_image` is a marketplace URN `publisher:offer:sku:version`; the
  Azure admin account must not be a reserved name (`root`, `admin`, `test`,
  ...), which restricts `node_username` and `jumphost_username`.
- **Credentials.** `azure_subscription_id` is a module variable (the
  storage account name and the checks use it). Tenant, client ID and secret
  exist only in the example root, where the `azurerm` and `azapi` providers are
  configured; the Azure CLI login is the default. azurerm 5 registers no
  resource providers: the example lists Compute, Network and Storage.
- **user_data budget.** `user_data_max_bytes` is 46000 (the base64 text is
  about 61 KB of the 64 KB limit; Step 0 settles whether the limit applies
  before or after base64), no per-file compression. The jumphost's
  `custom_data` is gzipped and checked against 87380 characters.
- **Resource group.** One per cluster, named `<cluster_name>`, created and
  deleted by the module unless `resource_group_name` names an existing group,
  which is never deleted.
- **Ingress backends** are the control planes (Traefik hostPorts), health
  checked on `/ping` 8080; the API rules share a TCP probe on 6443 (9345
  listens only after the join).

## Consequences
- The deploy needs no Azure credential on any VM and no CLI on the operator
  machine.
- The write SAS is in the jumphost's `custom_data`, hence in state: state is
  secret ([ADR 005](005-state-secrets.md)). It expires after 6 hours and
  cannot read, list or delete.
- Shared key access must be allowed on the storage account (the SAS is signed
  with the account key); an organisation policy that disables it needs a user
  delegation SAS, which is not implemented.
- A failed build leaves its blobs in the storage account; destroy removes the
  account with them.
- Capacity errors at create (`AllocationFailed`, `ZonalAllocationFailed`)
  cannot be checked at plan.
- Traefik and the API server see the original client address; the nodes' own
  traffic to the frontend is served locally, so it never leaves the node.
- The hairpin rules and the report-ready unit are build inputs through the
  butane hash: changing them rebuilds the image.
- The hairpin and the NVMe, Generation 2 and report-ready behaviours are
  unverified until Step 0 and the first end-to-end run.
- The OS disks are created with the VM (implicit OS disk) and carry no tags;
  only the resource group sweep of the leftover check finds them, and only for a
  group the module created.
