# Microsoft Azure platform notes

Platform behaviour that decides how the Azure module is built. Run it:
[`examples/azure/README.md`](../../examples/azure/README.md). Decision record:
[ADR 015](../decisions/015-azure-module.md). Plan and research:
[docs/plans/azure.md](../plans/azure.md).

**Status: implemented, untested against a real subscription.** `terraform
validate` and the plan logic pass with mocked providers. Nothing below is marked
verified until the Step 0 checks and a first end-to-end run are done; they are
listed at the end.

## Limitations

- Nodes have no public IP: `control_plane_public_ip` and a pool `public_ip`
  must be false, `placement` null, `kind` `"vm"`; each fails the plan.
- Generation 2 sizes with Premium SSD only (the OS disk is `Premium_LRS`).
- Security type Standard: no Trusted Launch, no Secure Boot (the VMs set both
  off; confirm with `az vm show --query securityProfile`).
- `vpc_mtu` is at most 1500: the module does not change the network MTU.
- One region per cluster; zones are `"1"`, `"2"`, `"3"`.
- Shared key access must be allowed on storage accounts (the upload SAS tokens
  are signed with the account key).
- Arm64 sizes are not supported.

## Passes: 1, and why

The load balancer and its static public IP exist before the image, the image
before the VMs, and backend pool membership is a separate resource per NIC added
with the VMs. No cycle, so one pass
([ADR 015](../decisions/015-azure-module.md)). Diagram:
[architecture](../architecture.md#azure-one-pass).

## Images

1. The jumphost (marketplace SLES 16, cloud-init `custom_data`) builds the raw
   image with podman, `qemu-img` rounds the virtual size up to 1 MiB and
   converts it to a fixed VHD (`-O vpc -o subformat=fixed,force_size`).
2. It uploads the VHD as a page blob with `curl` through a write-only container
   SAS (`create` and `write`): create the blob at its full size, then `Put Page`
   4 MiB chunks, 8 in parallel, skipping chunks that are all zeros, then a
   `done` marker (a block blob). It holds no Azure credential and the SAS is not
   logged.
3. Terraform polls the marker with a read SAS (`curl -sfI`, at most 90
   minutes).
4. `azurerm_shared_image_gallery`, a Generation 2 `azurerm_shared_image`
   (Linux, generalized, SCSI and NVMe, accelerated networking) and an
   `azurerm_shared_image_version` from the blob (`blob_uri`, up to two hours).
5. A delete SAS removes the VHD (`keep_build_artifacts = false`); the storage
   account stays in state, and `terraform destroy` removes it.

The SAS start and expiry are `time_offset` resources keyed to `build_hash`
(start 15 minutes back, expiry after 6 hours), so a plan does not drift. The
jumphost sets `ignore_changes = [custom_data]` (the write SAS is in it); a new
build replaces it through `build_trigger`. Names: storage account
`aif<12 hex of sha1(subscription/cluster_name)>`, container `images`, blob
`<cluster_name>-<build_id>.vhd`, gallery `<cluster_name with _>_gallery`,
definition `<cluster_name>-elemental`, version `1.0.<integer of the first 7 hex
digits of build_hash>`.

The image is rebuilt only when `build_hash` changes. `image_id` (a gallery image
version ID) skips the chain.

## Ignition, metadata and provisioning

- `ignition.platform.id=azure` (Ignition 2.14 or later for IMDS user data; the
  image ships 2.26). Kernel command line:
  `console=ttyS0,115200n8 console=tty0 quiet ignition.platform.id=azure`.
  Ignition reads `user_data` from the instance metadata service, base64, and
  uses `customData` only when it is empty. The nodes use `user_data`;
  `custom_data` is only on the jumphost.
- `user_data` is limited to 64 KB. `user_data_max_bytes` is 46000 and no
  per-file gzip is used. Whether the limit applies before or after base64 is
  open (Step 0).
- The image has no Azure agent. The VMs set `provision_vm_agent = false` and
  `allow_extension_operations = false`, and the baked `azure-report-ready` unit
  (every node) reads the goal state from the WireServer (`168.63.129.16`) and
  POSTs the "Ready" health report, with `curl` and `sed`. Without it the
  platform reboots the VM after about 20 minutes and the provisioning fails
  (`OSProvisioningTimedOut`). The unit retries for about 10 minutes; if the
  report is never accepted the unit exits 0 and only the platform's
  provisioning state stays open.
- The VM resource requires an admin account: `node_username` and the first SSH
  key are passed and ignored by the image (Ignition creates the user). Azure
  rejects reserved names (`root`, `admin`, `test`, ...), and the plan checks
  `node_username` and `jumphost_username`.
- Single NIC per node: `write-node-ip.sh` is not needed. Accelerated networking
  is on when the size supports it.
- Boot diagnostics are managed (`boot_diagnostics {}`); the serial console is
  `ttyS0`.

## Network

- Virtual network (`vpc_cidr`, default `10.20.0.0/20`, a /16 to /24): public
  subnet (low half, jumphost) and private subnet (high half, nodes), a NAT
  gateway with a static Standard public IP on the private subnet. Both subnets
  have `default_outbound_access_enabled = false`; the jumphost egresses through
  its own public IP. Subnets are regional.
- The public IPs (load balancer, NAT gateway, jumphost) set no zones: Standard
  addresses are zone-redundant by default in a region with zones, and the module
  ignores changes to their zones.
- NSGs on the NICs (`jumphost`, `control-plane`, `agent`) and application
  security groups (`control-plane`, `agent`) carry every inbound rule; there is
  no NSG on a subnet. Each NSG ends with a deny-all rule at priority 4096, since
  the platform's default rules allow all traffic inside the virtual network.
  Rule priorities start at 100, in the order of the sorted rule names.
- MTU: 1500 (`vpc_mtu` default); pod MTU = `vpc_mtu - 50`.

## Existing network

`vpc_id`, `public_subnet_id` and `private_subnet_id` (resource IDs, all three or
none) deploy into an existing virtual network instead of creating one. Set them
before the first apply: setting or clearing them later replaces the NSGs, the
load balancer and the nodes.

- The virtual network must be in `region` and the two subnets must be different
  subnets of it.
- Public subnet (jumphost): public IPs allowed.
- Private subnet (nodes): attached to a NAT gateway that has a public IP. This
  is required: the plan fails unless it has at least one public IP address or
  prefix. Nodes may reach the load balancer address through it, so every address
  and prefix is a client in the control-plane NSG and is listed in the
  `egress_ips` output (prefixes as CIDRs). The plan reads the subnet, the
  gateway, its addresses and its prefixes through azapi. `vpc_id` must be in
  `azure_subscription_id`.
- `vpc_cidr` becomes the virtual network CIDR: leave it null for the first
  address space, or set one of them. Both subnets must be inside it, and it must
  not overlap `10.42.0.0/16` or `10.43.0.0/16`.
- The module changes no subnet, route table, NSG or gateway of the network. NSGs
  that already sit on the subnets still apply, and traffic must pass both.
- Destroy leaves the network in place. `tools/leftovers/azure.sh` matches by the
  `elemental-cluster` tag, which the network does not carry.

Find the IDs:

```bash
az network vnet list --query '[].{name:name,id:id,rg:resourceGroup,cidrs:addressSpace.addressPrefixes}' -o table
az network vnet subnet list --vnet-name <vnet> -g <rg> \
  --query '[].{name:name,id:id,cidr:addressPrefix,nat:natGateway.id}' -o table
```

## Resource group

`resource_group_name` null creates a group named `<cluster_name>` and deletes it
on destroy. A name selects an existing group, which is never deleted: the
module's resources are removed one by one.

## Nodes

One `azurerm_linux_virtual_machine` per node, keyed by hostname
(`<cluster_name>-cp-NN`, `<cluster_name>-<pool>-NN`), in the private subnet,
from the gallery image. Its NIC is `<hostname>-nic`; the NIC carries the NSG, the
application security group and, for control planes, the backend pool
membership. The Ignition of the node is the base64 `user_data`;
`ignore_changes = [user_data]` keeps a changed value from replacing a running
node (Ignition runs on first boot only), and a new image replaces every node
(`replace_triggered_by`). Disks: `control_plane_disk_size_gb` (default 100) and
200 GB for agents unless a pool sets `disk_size_gb`, `Premium_LRS`, `ReadWrite`
caching. Sizes are Azure names (`Standard_D8s_v5`); NVMe-only sizes (the `_v6`
families) get the NVMe disk controller, others SCSI.

Placement: control planes go round-robin over `zones`; a pool without `zone`
spreads over `zones` the same way, a pool `zone` pins it (it must be one of
`zones`). `zones` defaults to the region's zones (from the subscription's
locations list); a size restricted or not offered in a zone a node lands in
fails the plan. A region without zones gives none and nothing is pinned.
The jumphost is not pinned.

Jumphost: it exists while the image is built and whenever `deploy_nodes` is true
(SSH bastion, `ProxyJump`). The login user is `jumphost_username`, `azureuser`
when empty. With `image_id` set it builds nothing; with `image_id` set and
`deploy_nodes = false` there is none. Default image
`SUSE:sles-16-0-x86-64:gen2:latest`, a marketplace URN
(`publisher:offer:sku:version`); whether the offer needs plan acceptance is open
(Step 0).

## Load balancer

A public Standard load balancer on a static public IP; one rule per port for
6443, 9345, 80 and 443 (frontend port = backend port, `floating_ip_enabled =
false`, `disable_outbound_snat = true`, TCP reset, 30 minute idle timeout).
Backends are the control planes (NIC pool membership). Probes: TCP on 6443 for
both API rules (9345 listens only after the join) and Traefik's `/ping` on 8080
for ingress, every 10 seconds, threshold 2. Probes come from the
`AzureLoadBalancer` service tag, which the control-plane NSG admits on the probe
ports. Egress is carried by the NAT gateway.

The load balancer does not rewrite the client address, so `api_cidrs` (6443) and
`ingress_cidrs` (80, 443) are enforced by the control-plane NSG, which also
admits the NAT addresses on every listener (nodes may reach the frontend through it)
and, for 6443 and 9345, the node application security groups. Traefik and the
API server see the client address.

Hairpin: control planes dial the frontend they sit behind (the image knows one
address): joins, API calls, and in-cluster clients of the Rancher hostname. A
Standard load balancer does not serve a backend that connects to its own
frontend reliably. The baked `azure-lb-hairpin` timer (every 15 seconds, control
planes only) keeps an nft table `azure-lb-hairpin` with `ip daddr <frontend>
tcp dport {6443, 9345} dnat to <own private IP>` in `output` and `prerouting`,
only while the local 6443 answers; a missing table is recreated on the next run.
Ingress (80, 443) is not redirected: the DNAT would pre-empt the CNI hostPort
rule and Traefik would get a reset. Whether a pod on a control plane reaches the
Rancher hostname through the frontend is open (Step 0.6), as is whether the
hairpin occurs at all (the NAT gateway may carry the flow). Choice and prior
art: [ADR 015](../decisions/015-azure-module.md). Check it on a control plane
(`su -`): `nft list table ip azure-lb-hairpin`.

## Labels

Azure tags with the managed `elemental-*` keys on every taggable resource, per
[conventions](../conventions.md#labels). Tag keys exclude `< > % & \ ? /`; the
managed keys fit. NICs, VMs and the image version also carry `elemental-pool`
and `elemental-build` where they apply. The NSG rules carry no tags, and
neither do the OS disks: the VM resource creates them implicitly. The resource
group sweep of the [leftover check](#leftover-check) still finds them when the
module created the group.

## GPUs

Candidates: `Standard_NC4as_T4_v3` (cheap test), `Standard_NV36ads_A10_v5`,
`Standard_NC24ads_A100_v4`, `Standard_NC40ads_H100_v5`,
`Standard_ND96isr_H100_v5`. New subscriptions have a quota of 0 vCPUs for a GPU
family in every region, and increases are requested manually (portal:
Subscriptions, Usage + quotas). GPU nodes are agents and carry the pool's `gpu`
role label. Not tested: whether the precompiled driver loads, and whether the
accelerated networking device is left alone by NetworkManager. Arm64 sizes
(GB200) and fractional vGPU sizes are out of scope.

## Quota and availability

Plan-time hard fails (`terraform_data.limits_check`, azapi reads):

- Each size must be offered in the region, not restricted for the subscription
  (`NotAvailableForSubscription`), support Generation 2 and Premium SSD, and be
  offered in its zone (`Microsoft.Compute/skus`).
- vCPUs per family and Total Regional vCPUs
  (`Microsoft.Compute/locations/<location>/usages`), summed from the node list
  (control planes, pools and the jumphost while it exists).
- Standard public IPs (load balancer, jumphost and, for a created network, the
  NAT gateway) and Standard load balancers
  (`Microsoft.Network/locations/<location>/usages`).
- What the cluster already holds (VMs, Standard public IPs and load balancers
  tagged `elemental-cluster`) is subtracted, so a re-plan does not fail on its
  own usage.

Capacity can still run out at create (`AllocationFailed`,
`ZonalAllocationFailed`).

## Security

- The jumphost is the only SSH entry; it holds no Azure credential (write-only
  SAS). The SAS is in its `custom_data` and in state; it expires after 6 hours
  and cannot read, list or delete.
- Instances never read from storage; the jumphost uploads only.
- The container is private and public blob access is off; TLS 1.2 or later.
- The `AzureLoadBalancer` source and the application security groups keep the
  node ports closed to the rest of the virtual network.

## Cost estimate

`make cost PROVIDER=azure TFVARS=...` estimates the cost from tfvars
([tools/cost](../../tools/cost/README.md#azure)). Rates come from the public
Azure Retail Prices API (no key, cached per region, USD). It prices the VMs per
size, the Premium SSD OS disks (smallest tier that holds the size), the Standard
public IPs, the load balancer rules and the NAT gateway. Outbound traffic, data
processed by the load balancer and the NAT gateway, the jumphost's SLES licence
meter and image storage are not included. The result is an estimate, not a
quote.

## Leftover check

```bash
tools/leftovers/azure.sh <cluster_name> [--project <subscription>] [--all]
```

Read-only. Uses the `az` CLI and `jq`; credentials come from the CLI login, never
the tfvars. For Azure, `--project` is the subscription (ID, or a name without spaces); without it
the `az` default subscription is used. `deploy.sh` passes `azure_subscription_id`
when set; `deploy.sh --destroy` prints the command at the end and never runs it.

Two lookups:

- `az resource list --tag elemental-cluster=<cluster_name>`: every tagged
  resource in the subscription, in any resource group (this covers a
  `resource_group_name` you supplied).
- The resource group `<cluster_name>` and everything in it: NICs, disks and
  public IPs can outlive a VM without the tag.

Exit 0 means nothing is left, 1 something is, 3 the check was inconclusive (CLI
missing, a list or show call failed). Nothing is deleted or suggested. A group
named `<cluster_name>` without the cluster tag may be unrelated: it and its
contents are reported as `UNKNOWN`, not `LIVE`. An existing network or resource
group you supplied is not listed unless it carries the tag. The OS disks carry
no tag; the resource group sweep finds them only when the module created the
group.

## Operational limits

- `user_data` 64 KB; the jumphost's `custom_data` is gzipped and checked against
  87380 characters.
- The marketplace SLES image ships `curl` and the build installs podman and
  `qemu-tools` with `zypper`.
- `keep_build_artifacts = true` leaves the VHD in the storage account; destroy
  removes the account with it.
- A failed build leaves its blobs in the account; the next build writes other
  names. Destroy removes the account and them.
- The write SAS must outlive the upload: 6 hours. An expired token shows as
  HTTP 403 in the build wait or the VHD delete; `deploy.sh --rebuild` creates a
  new one.
- Report ready: the unit retries for about 15 minutes (60 tries, 15 seconds
  apart), inside the platform's provisioning window.

## Still open (Step 0)

Nothing is verified. The checks, in order, are in the
[plan](../plans/azure.md#step-0-blockers-manual-once-the-account-is-ready); the
plan records the results.

1. Subscription: `Microsoft.Compute`, `Microsoft.Network` and
   `Microsoft.Storage` registered, GPU quota requested, a region with three
   zones and the GPU size.
2. Shared key access allowed on the storage account (an organisation policy may
   disable it).
3. Boot test: raw image to fixed VHD to page blob to Generation 2 gallery image
   (confirm `az vm show --query securityProfile` reports Standard), `az vm create` with `--enable-agent false` and a
   minimal Ignition with the report-ready unit. Boot (`hv_storvsc` in the
   initrd), Ignition reads `userData`, the VM reaches `Succeeded`, NIC and MTU,
   serial log content and refresh rate.
4. An NVMe-only size (`_v6`) and `Standard_NC4as_T4_v3`: GPU visible,
   precompiled driver loads, the accelerated networking device (`mlx5`, MANA) is
   not taken over by NetworkManager.
5. `user_data` size: about 60 KiB raw (fails?) and about 47 KiB raw (passes), to
   settle before or after base64.
6. Load balancer hairpin: with `azure-lb-hairpin.timer` disabled first, measure
   a control plane reaching `<frontend>:9345/6443/443` (control-plane flows to
   the public frontend may be SNATed by the NAT gateway, so the hairpin may not
   occur), then with the DNAT (6443 and 9345 only). Also open: 443 from a pod
   on a control plane (the ingress hairpin is not redirected).
7. Jumphost image: `az vm image show --urn ...` (is `plan` null, is plan
   acceptance needed).

Also open: whether Ignition's `azure` provider needs the initrd network drivers
(`hv_netvsc`, `mana`, `mlx5_core`) beyond what the image carries, the format of
the build progress (serial log versus a relay), and the first end-to-end run
([e2e checklist](../e2e-checklist.md#azure)).

## Run it

The command runbook (tfvars layering, deploy, checks) is in
[`examples/azure/README.md`](../../examples/azure/README.md#end-to-end-runbook).

## Sources

- [Creating generalized images without a provisioning agent](https://learn.microsoft.com/en-us/azure/virtual-machines/linux/no-agent)
- [Generic Linux VHD requirements](https://learn.microsoft.com/en-us/azure/virtual-machines/linux/create-upload-generic)
- [Azure Load Balancer floating IP](https://learn.microsoft.com/en-us/azure/load-balancer/load-balancer-floating-ip)
- [Load balancer platform limitations](https://learn.microsoft.com/en-us/troubleshoot/azure/load-balancer/troubleshoot-load-balancer-platform-limitations)
- [Default outbound access](https://learn.microsoft.com/en-us/azure/virtual-network/ip-services/default-outbound-access)
- [User data](https://learn.microsoft.com/en-us/azure/virtual-machines/user-data)
- [Ignition Azure provider](https://github.com/coreos/ignition/blob/main/internal/providers/azure/azure.go)
- [azurerm 5.0 upgrade guide](https://github.com/hashicorp/terraform-provider-azurerm/blob/main/website/docs/guides/5.0-upgrade-guide.html.markdown)
- [Azure Retail Prices API](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices)
