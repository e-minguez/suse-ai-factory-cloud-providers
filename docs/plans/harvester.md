# Plan: SUSE Harvester provider

Status: implementation on feat/harvester (v1 scope: existing networks only; no
network creation). Step 0 passed on 2026-11-18 (results below).

Goal: `modules/harvester` + `examples/harvester` at parity with the other
providers: same common variables, outputs, labels, `deploy.sh` interface,
plan-time availability hard-fails, leftovers script, catalog plans, CI job,
webui entry. Harvester is on-premises: no cost estimate, no quota API.

## Naming

Provider directory and identifier: **`harvester`** (Terraform provider
`harvester/harvester`). Docs title: "SUSE Harvester".

## Decisions taken

- **Minimum Harvester 1.8**, provider `harvester/harvester` `>= 1.8.0`
  (provider versions match Harvester versions since 1.6). 1.8 brings
  `harvester_image` `file_path` upload and is the oldest release the module
  is tested against.
- **Image delivery: disk export.** The jumphost writes the raw image to a
  `harvester_volume` with `dd`; `harvester_image` with
  `source_type = "export-from-volume"` turns that volume into the node image.
  Harvester never has to reach the jumphost over the network (no HTTP
  download from the jumphost).
- **HA: elemental3 managed VIP.** `api_vip_mode = "managed"` (already
  supported by `modules/elemental-config`, unused so far): MetalLB L2 plus
  endpoint-copier-operator expose 6443/9345 on a static VIP.
- **Network: an L2 VLAN network with DHCP and egress from the physical
  network.** Overlay networks (Kube-OVN VPCs) and the mgmt network are out of
  scope (reasons under "Network").

## Facts checked (2026-11-17)

- **Terraform provider**: latest 1.9.1 (2026-11-09). Resources: `image`
  (`source_type` `download | upload | export-from-volume | clone`, `backend`
  `backing-image | cdi`), `virtualmachine` (`efi`, `secure_boot`,
  `machine_type`, `cloudinit` noCloud/configDrive with `user_data_secret_name`,
  `network_interface` with `mac_address` and `wait_for_lease`, `disk` with
  `storage_class_name`, `hot_plug`, `existing_volume_name`, `host_device`,
  `node_selector`, `run_strategy`), `volume`, `network`, `vlanconfig`,
  `clusternetwork`, `ippool`, `loadbalancer`, `pcidevice`, `cloudinit_secret`,
  `ssh_key`, `storageclass`, `setting`. Each also exists as a data source.
  Auth: `kubeconfig` (path or base64 content; content lands in state).
- **Ignition**: platform `kubevirt` reads the ConfigDrive (`config-2`) since
  2.14 and the NoCloud (`cidata`) `/user-data` since 2.24. The Elemental base
  OS `registry.suse.com/beta/uc/base-os-kernel-default:16.1-73.2` ships
  **ignition 2.26.0** (read from its rpmdb), so Harvester's default NoCloud
  disk works. Ignition does not gunzip on this platform: user_data is plain
  JSON. Kernel arg `ignition.platform.id=kubevirt`.
- **Base OS image**: no cloud-init; qemu-guest-agent is installed and udev
  starts it when KubeVirt adds the agent port (checked 2026-11-18: VMI
  `AgentConnected=True`, IP and guestOSInfo reported, nothing in Ignition;
  an earlier rpmdb search missed it because the package is built from the
  `qemu` source RPM). Nodes use `wait_for_lease`.
- **elemental3 managed VIP**: `network.apiVIP` + `apiVIPMode: managed` makes
  elemental add the `metallb` and `endpoint-copier-operator` charts (versions
  from the release manifest: MetalLB 0.15.2, endpoint-copier-operator 0.3.0)
  and a `k8s-vip.yaml` (`IPAddressPool` `<vip>/32`, `L2Advertisement`,
  `Service default/kubernetes-vip` type LoadBalancer on 6443 and 9345).
  Joining nodes use `https://<vip>:9345`; `apiVIP` and `apiHost` are added to
  `tls-san`. The init node deploys MetalLB, so the VIP answers only after the
  init node's RKE2 is up; joiners retry. **API only**: ingress needs its own
  pool (see "Ingress VIP"). Open issue
  [SUSE/elemental#487](https://github.com/SUSE/elemental/issues/487)
  (secondary servers retry the RKE2 install when the VIP is announced early).
- **Jumphost image**: openSUSE Leap 16.0 Minimal-VM Cloud qcow2
  (`https://download.opensuse.org/distribution/leap/16.0/appliances/Leap-16.0-Minimal-VM.x86_64-Cloud.qcow2`)
  carries cloud-init (NoCloud) and qemu-guest-agent, and has zypper for
  `modules/image-factory`. SLES and SL Micro images need an SCC login; Leap
  Micro boots with Ignition/Combustion, not cloud-init.
- **Image backends**: Longhorn V1 uses backing images (`backing-image`);
  CDI (`cdi`) serves Longhorn V2, LVM and third-party CSI and pins the image
  to one StorageClass. Images downloaded from Harvester since v1.5.5 are
  gzip-compressed.
- **Overlay networks (Kube-OVN, v1.6+)** have VPCs, subnets and NAT
  gateways, but only on the mgmt cluster network, are not reachable from
  outside, ignore static IPs in cloud-init, do not support the Harvester load
  balancer, and `harvester_network` has no overlay type.
- **GPU**: PCI passthrough via the `pcidevices-controller` add-on:
  `harvester_pcidevice { passthrough_enabled = true }` binds the device to
  vfio-pci, the VM requests it with `host_device { name, device_name }`.
  NVIDIA vGPU (SR-IOV since 1.3, MIG since 1.7) needs a vGPU host licence and
  the vGPU guest driver; the precompiled datacenter driver override does not
  cover it.

## Test environment (`harvester-hpc`)

- Harvester 1.8.2, upgrading to 1.9.1 on 2026-11-17. 11 hosts
  (`hpc3u25`–`hpc3u35`, three control plane), Longhorn V1 storage
  (default StorageClass `harvester-longhorn`). Shared cluster with
  per-user namespaces; test namespace **`suse-ai-factory-on-harvester`**.
- The API certificate is Harvester's self-signed dynamic certificate with IP
  SANs only. The kubeconfig's hostname fails TLS verification; the server URL
  `https://10.114.128.125/k8s/clusters/local` verifies against the
  kubeconfig's CA. The docs must cover this (IP in `server:`, or a proper
  certificate in the `ssl-certificates` setting).
- Network `harvester-public/vlan-2006` (bridge on `mgmt-br`, VLAN 2006,
  `promiscMode: true`). Subnet `10.114.128.0/25`, DHCP pool `.50`–`.120`
  (10-minute leases, served by a container outside Harvester), gateway
  `.126`, DNS `10.113.53.53`/`.54`, Harvester VIP `.125`, hosts `.25`–`.35`.
  Harvester's own route probe reports "DHCP failed" for this network; VMs on
  it do get leases (active leases on 2026-11-16).
- Outside the DHCP pool, `.36` and `.124` answer ping; `.1`–`.24`,
  `.37`–`.49` and `.121`–`.123` do not. **Proposed VIPs: API `10.114.128.40`,
  ingress `10.114.128.41`** (to be confirmed as unreserved).
- No GPUs and `pcidevices-controller` disabled: the first test is CPU only.
- Existing images in `harvester-public`: Tumbleweed and SLES 16.0 cloud
  images, no Leap 16.0.

## Step 0: checks on the test cluster

Run 2026-11-17/18 on Harvester 1.8.2 (upgrade to 1.9.1 pending), with
`kubectl` manifests in namespace `suse-ai-factory-on-harvester`; all test
objects deleted afterwards. **All passed.**

1. **Export from an attached volume: PASS (running VM, volume attached).**
   - Leap 16.0 jumphost (4 vCPU, 8 GiB, EFI) with a blank 20 GiB Block RWX
     PVC as a second virtio disk (`serial`), attached in the VM spec, not
     hot-plugged. `dd bs=4M conv=fsync` of the 8 GiB raw took 76–90 s;
     the sha256 read back from the device matched.
   - `VirtualMachineImage` `sourceType: export-from-volume` (`pvcName`,
     `pvcNamespace`) with the jumphost running reached `Imported=True` in
     about 4 minutes, three runs out of three. Stopped VM or detached volume
     not needed.
   - The image is the size of the **whole volume** (20 GiB), not of the raw.
     Each image gets its own StorageClass (`lh-<uuid>`, in
     `.status.storageClassName`).
   - Harvester refuses to attach a PVC that another VM already uses, even a
     stopped one.
2. **Elemental boot: PASS.**
   - Minimal elemental config built with `registry.suse.com/beta/uc/elemental:3.1.0-6.5`
     (`customize --type raw`, 2.5–3.5 min), the repo's
     `core_platform_override` defaults, kernel command line
     `console=ttyS0 ignition.platform.id=kubevirt`.
   - Node VM: EFI (`secureBoot: false`), q35, virtio root disk from the
     image, bridge NIC with a fixed MAC, NoCloud
     `cloudInitNoCloud.secretRef` (secret key `userdata`).
   - Serial log: `Ignition 2.26.0`, mounts `/dev/disk/by-label/cidata`,
     `fetched user config from "kubevirt"` (no network needed). SSH as the
     Ignition user worked; DHCP address in `10.114.128.0/25`, MTU 1500,
     default route `.126`, same address on every boot with the same MAC.
   - First boot takes 5–7 minutes from VM create to SSH: about 3 minutes to
     attach the root PVC (backing image copy; transient
     `FailedAttachVolume DeadlineExceeded` events), then the recovery
     autoinstall, a reboot, and Ignition.
   - Butane must keep the `/home` filesystem entry (the repo's does), or
     `useradd` fails and the node drops to the emergency shell.
3. **Egress: PASS.** `registry.suse.com` and `registry.rancher.com` (401),
   `download.opensuse.org` (200) through gateway `.126`; DNS from DHCP.
4. **L2 VIP on the KubeVirt bridge: PASS.** `10.114.128.40` added on one VM
   with gratuitous ARP was reachable from the runner (routed through `.126`)
   and from the other VMs. No MAC/IP spoof filtering.
   - Move with gratuitous ARP: about 1.5 s loss from the runner.
   - Live migration of the VM holding the VIP: 2 of 114 pings lost.
   - Move **without** gratuitous ARP: the gateway kept the old MAC for about
     7.5 minutes. MetalLB sends gratuitous ARP; nothing else should move the
     VIP.
5. **Host spread: PASS on the platform, not expressible in the provider.**
   - A preferred podAntiAffinity on a per-group label put 3 VMs on 3 hosts.
   - `harvester_virtualmachine` has `node_selector` only (since 1.7.0); no
     affinity fields up to 1.10.0-rc2. The provider always adds Harvester's
     default preferred podAntiAffinity (weight 100, `kubernetes.io/hostname`,
     against every VM with the `harvesterhci.io/creator` label), so VMs
     spread against all Terraform/UI-created VMs, not per cluster.
   - Harvester adds a required nodeAffinity `network.harvesterhci.io/mgmt=true`
     for networks on `mgmt-br`.
6. **user_data size: PASS up to 920,429 bytes.** Ignition configs of 64 KiB,
   512 KiB and ~900 KiB in the secret were accepted and fully applied (marker
   file last). The ceiling is the 1 MiB Secret limit.

## Design

### Passes

**1 pass** (Step 0.1): the image waits for the build-done signal and is
exported while the running jumphost still holds the volume.

### Build-done signal

HTTP status file on the jumphost, like the other providers that wait on a
URL. The jumphost is the builder, so there is no relay (evroc needs
`status-relay.py` because separate builders push to it): the
`hook_on_step`/`hook_on_exit` hooks of `modules/image-factory` write
`<build_id> <step|done|failed> <detail>` to a file, and
`python3 -m http.server --directory` serves it read-only on the jumphost's
vlan address. `wait-for-image.sh` polls it with `curl` through
`scripts/lib/poll.sh`, checks the `build_id`, and fails fast on `failed`
(pointing at `scripts/build-logs.sh`). The runner reaches vlan-2006 (the VIPs
have to be reachable anyway). CLAUDE.md: add harvester to the accepted
`python3 -m http.server` uses.

### Auth and provider variables (`modules/harvester/variables.tf`)

- `kubeconfig_path` (path only, so the content stays out of state) and
  optional `kubeconfig_context`. Goes in `common-harvester.tfvars`.
- `namespace`: existing namespace for every object (shared clusters). The
  provider has no namespace resource; the plan fails if the namespace
  does not exist.
- `storage_class_name` (default: cluster default) and `image_backend`
  (`backing-image` default, `cdi`).

### Sizes

Harvester has no instance types. `*_instance_type` takes
`<cpu>x<memory_gb>` (`8x32`), parsed in `locals.tf`, as for OCI flex shapes.
GPU pools add a PCI device name (`harvester_pcidevice` name) per GPU.

### Network (`network.tf`)

- **Existing network** (default and only mode on shared clusters): `vpc_id` =
  `<namespace>/<name>` of a Harvester VM network; `vpc_cidr` = its real
  subnet (required: `write-node-ip.sh` and MetalLB use it).
- **Created network** (optional): `harvester_clusternetwork` +
  `harvester_vlanconfig` (uplink NICs) + `harvester_network` (`vlan_id`).
  Cluster-scoped objects: only for dedicated clusters.
- One NIC per node (vlan-2006 only); no mgmt NIC, so `write-node-ip.sh` is a
  no-op.
- DHCP from the physical network. The data source checks the network exists
  and is an L2 VLAN network.
- **No security groups** on VLAN networks: `admin_cidrs`, `api_cidrs` and
  `ingress_cidrs` cannot be enforced by the platform. They are accepted and
  documented as not enforced (`docs/providers/harvester.md`): filtering is
  the job of the network the VMs are attached to.

### API and ingress VIPs

- New provider variables `api_vip` and `ingress_vip`: static IPv4 addresses
  inside `vpc_cidr`, outside the DHCP range. Validation: inside `vpc_cidr`,
  distinct, not the network or broadcast address.
- `api_vip_mode = "managed"`; `api_host` defaults to `<api_vip>.sslip.io`,
  `rancher_hostname`/`ingress_domain` to `<ingress_vip>.sslip.io`.
- **Ingress VIP** (new in `modules/elemental-config`, when the mode is
  managed and `ingress_vip` is set): `IPAddressPool` `<ingress_vip>/32`
  scoped by `serviceSelector` to the ingress controller Service,
  `L2Advertisement`, and a HelmChartConfig switching Traefik (or
  ingress-nginx) to `type: LoadBalancer`, `externalTrafficPolicy: Local`.
  Feeds `build_hash` through the rendered manifests.
- No hairpin issue: the VIPs are on the nodes' L2 segment.

### Image pipeline (`build.tf`, `image.tf`)

1. `harvester_image` `jumphost`: Leap 16.0 Cloud qcow2 by URL (`download`),
   unless `jumphost_image` names an existing image (`<namespace>/<name>`).
2. `harvester_volume` `image_target` (blank, `image_disk_size`, Block). Its
   size is the node image size (Step 0.1), so it also bounds the node root
   disk minimum.
3. `harvester_virtualmachine` `jumphost` (EFI, NoCloud cloud-init, root disk
   from the jumphost image, `image_target` as a second virtio disk with a
   `serial`, vlan-2006 NIC). `modules/image-factory` with zypper;
   `hook_deliver_raw` writes the raw to `/dev/disk/by-id/virtio-<serial>`
   with `dd conv=fsync`. A new `build_id` needs a new volume (Harvester does
   not share a PVC between VMs and the old image stays until nodes move).
4. `terraform_data.wait_for_build` (`triggers_replace = [build_id]`):
   `wait-for-image.sh` on the build-done signal.
5. `harvester_image` `node`: `export-from-volume` of `image_target`, named
   after `build_id`; recreated only when `build_hash` changes.
6. `image_id` skips 1–5 (existing node image `<namespace>/<name>`).

Kernel command line: `ignition.platform.id=kubevirt`, serial console
`ttyS0` (Harvester serial console available).

### Nodes (`nodes.tf`)

- One `harvester_virtualmachine` per node: EFI, `machine_type` q35, root disk
  from the node image (`*_disk_size_gb`, `storage_class_name`), one NIC on
  the network, user_data in a `harvester_cloudinit_secret` (NoCloud),
  `wait_for_lease` (guest agent). `replace_triggered_by` the node image. Root disks
  `auto_delete = true` (deleting a VM keeps its PVCs otherwise, and an image
  cannot be deleted while a PVC from it exists).
- **Fixed MAC per node**, derived from cluster and node name (locally
  administered `02:` prefix): same DHCP address across reboots and a key for
  DHCP reservations.
- Host spread: the provider's default preferred anti-affinity (Step 0.5);
  no `node_selector` pinning by default, which would block live migration
  during Harvester upgrades. `zones` rejected beyond one entry. A
  per-cluster anti-affinity needs a provider feature (upstream request).
- `control_plane_public_ip` and pool `public_ip` rejected (no public IPs).
- GPU pools: `host_device` per GPU, `node_selector` to the host holding the
  device; `harvester_pcidevice` passthrough is not managed by the module
  (cluster-scoped; a precondition checks it is enabled).
- user_data limit: `user_data_max_bytes = 900000` (Step 0.6, under the
  1 MiB Secret limit); no gzip.
- Boot timeouts sized for a 5–7 minute first boot (Step 0.2).

### Jumphost lifecycle

SSH entry for nodes (convention: `ProxyJump` via jumphost) and build host.
It exists while building and whenever nodes exist; with `image_id` it carries
no build payload. Its `public_ip` output is its vlan address.

### Labels

`elemental-*` labels on VMs, volumes, images and secrets (Kubernetes labels);
`role`, `pool`, `build` where they apply. Harvester labels are Kubernetes
labels, so no `/` in keys holds naturally.

### Availability (`availability.tf`, hard-fail)

Data sources: namespace exists, network exists, storage class exists, node
image / jumphost image exist (when given), PCI devices exist and are bound for
passthrough, VIPs inside `vpc_cidr`. Host CPU/memory capacity cannot be read
through the provider: not checked.

### Outputs

Standard set. `provider_details`: namespace, network, storage class, image
names, VIPs.

## Tooling and repo touchpoints

- `modules/harvester` (+ `variables-common.tf` symlink), `examples/harvester`
  (`deploy.sh`, tests, `catalog.tftest.hcl`), `docs/providers/harvester.md`
  (including the openSUSE image upload: Terraform URL download, UI
  Images → Create → URL/File, `VirtualMachineImage` manifest, `file_path`
  upload for disconnected clusters).
- `modules/elemental-config`: ingress VIP manifests; `user_data` without gzip.
- `tools/leftovers/harvester.sh` (`kubectl` by label in `namespace`).
- `tools/cost`: excluded (on-premises).
- webui: `ui.yaml` entry; Dockerfile: no new CLI unless leftovers needs
  `kubectl` in the image.
- CI: `validate (harvester)` job; add it to the `protect-main` ruleset
  (18 required checks).
- ADR `013-harvester-module.md` (1 pass, disk export, HTTP build status,
  managed VIPs). `docs/architecture.md`: network diagram with MetalLB VIPs.

## PR sequence

1. `modules/elemental-config`: ingress VIP for managed mode (+ tests).
2. `modules/harvester` + `examples/harvester` + docs + CI job.
3. Catalog shapes and webui entry.

## Risks

- DHCP leases of 10 minutes on a shared 71-address pool: a control plane that
  comes back after its lease expired may get another address, which breaks
  etcd membership. Fixed MACs keep the address while the lease lives;
  DHCP reservations by MAC (documented) or static node addresses in Ignition
  (later) remove the risk.
- Without gratuitous ARP a VIP move takes minutes at the gateway (Step 0.4);
  only MetalLB may own the VIPs.
- Control planes can share a Harvester host (soft anti-affinity only).
- VIPs collide with an address someone else uses without a lease; nothing at
  plan can detect it.
- elemental#487 retries on secondary servers; joins may be slow.
- Exported image size equals the volume size (`image_disk_size`): keep it
  small (the raw is 8 GiB for a minimal build).

## Open decisions

None. Settled on 2026-11-17: CIDR variables accepted and documented as not
enforced; build-done signal over HTTP.

## To do / to check (2026-11-18)

1. **`node_storage_classes`** (per node group StorageClass: `cp`, pool keys,
   `jumphost`; one image export per class, since Harvester clones images only
   to encrypt them). On `feat/harvester` (`77654c5`), tests pass. The HA run
   had every disk on `yolo`, so the mixed case is not run yet: a deploy with
   `{ cp = "yolo" }` and `storage_class_name` unset (control planes on the
   single-replica class, agents and jumphost on replicated Longhorn, two
   image exports).
2. **Powered-off build host:** implemented and **e2e passed** (2026-11-19, HA
   run: 3 control planes + 1 agent, rancher + aif-operator). `on_exit` hook powers off after a successful build once a GET of the
   status file follows `done` (journal of `image-status.service`, 30 min at
   most); `wait-for-image.sh` then waits for the status URL to stop answering
   (15 min, then warns and exports from the running VM). Role label `builder`;
   no jumphost with `image_id`; `scripts/lib/ssh.sh` connects directly when the
   jumphost has no address (nodes keep `private_ip`), and the state fallback
   only applies while no image exists. `buildhost_power_off` (default true).
   Renamed to build host: harvester-owned names say `buildhost`
   (`harvester_virtualmachine.buildhost`, VM `<cluster>-buildhost`,
   `buildhost_image_url`, `node_storage_classes` key `buildhost`,
   `provider_details.buildhost_image`); common `jumphost_*` and the `jumphost`
   output stay.
   Verified: power-off after the build, export from the stopped VM's volume
   (Step 0 case 1b), `ssh.sh` and `kubeconfig.sh` straight to the nodes. Found
   and fixed on that run: the `jumphost` output kept the creation-time address
   (now null with `buildhost_power_off`), and provider 1.9.1 reports the
   cloud-init disk as a disk (perpetual in-place update of every VM;
   `ignore_changes = [disk]`, harvester/harvester#10728). Chart order on that
   run: metallb first (13:03), aif-operator done 13:09, `kubernetes-vip`
   created right after: the VIP still waits for every chart.
3. **Managed VIPs depend on every chart** (elemental installer): charts install
   in `release.yaml` order with `metallb`/`endpoint-copier-operator` appended
   last, and `deployHelmCharts` exits 1 on any failed chart, so `deployManifests`
   (`k8s-vip.yaml`, `ingress-vip.yaml`) never runs and joining nodes cannot
   reach `apiVIP:9345`. Asked the elemental team about prioritising charts and
   manifests. Fallbacks if not: (a) list `metallb` and `endpoint-copier-operator`
   first in `release.yaml` in managed mode; (b) ship the VIP manifests through
   RKE2's manifests directory (RKE2 retries until the CRDs exist; the installer's
   later `create` hits `AlreadyExists`, which it treats as success). (b)
   duplicates elemental's `k8s-vip.yaml`: needs a workaround entry. **(a)
   done** (2026-11-19, `docs/workarounds.md`). The installer script
   (`k8s_res_deploy.sh.tpl`) waits for each chart in order and applies the
   non-priority manifests only after the loop and only if no chart failed, so
   (a) installs MetalLB first but the VIP still waits for every chart; only (b)
   decouples it.
4. **HDD test cluster:** etcd on `yolo` averaged ~150 ms and timed out during
   the `aif-operator` install. Redeployed 2026-11-18 with
   `etcd_unsafe_no_fsync = true` (DANGEROUS) on `yolo`: **single-node e2e
   passed** (checked 2026-11-19). The `aif-operator` Helm job took 61 min
   (1 restart), then MetalLB and endpoint-copier installed;
   `kubernetes-vip` on `.40` (kubectl through the VIP works), Traefik on `.41`,
   Rancher `/ping` 200 at `https://rancher.10.114.128.41.sslip.io`, all pods
   Running, etcd lifetime average still ~175 ms. etcd config confirmed
   `unsafe-no-fsync: true` (2026-11-19), so fsync is not the main cost of the
   remaining latency. **HA bootstrap passed** (2026-11-19): 3 control
   planes + 1 agent, everything on `yolo`, `disk_cache_mode = "writeback"`,
   after enabling the drive write cache and mq-deadline on the lab hosts (no
   controller cache: 4 KiB sync writes 21 ms → 1.6 ms). Apply 12 min, VIP up
   ~6 min after etcd start, agent and both control planes joined through
   `apiVIP:9345` within ~9 min, 3 etcd members. MetalLB moved the VIP from
   cp-01 to cp-03 by itself as speakers joined. The earlier attempt with the
   agent and jumphost on 3-replica Longhorn and no host tuning stalled
   (IO pressure `full` ~41 % on cp-01). **VIP move passed:** halting the
   announcing control plane (cp-03) moved `.40` to cp-01 at once; a 1 s
   `/healthz` probe saw two ~3 s gaps (the move, then most likely a stale
   cp-03 backend in `kubernetes-vip` until its lease expired), stable after
   ~10 s. With cp-03 down the cluster stayed usable (2/3 etcd) and the
   `kubernetes-vip` EndpointSlice dropped its address; after restart cp-03
   was Ready again in ~2 min and back in the slice. Not yet run: the full
   catalog 02 shape (storage pool, GPU pool).
5. **Still unverified:** nginx ingress label for the ingress pool; root-disk
   PVCs carry no `elemental-*` labels (leftover check misses them); GPU pools
   (`gpu_pools`) on hardware; destroy "image in use" retry; ruleset
   `validate (harvester)` after merge.
6. **GPU passthrough passed (2026-11-25)** on a second cluster: Harvester
   1.10.0-rc3, one host (144 vCPU, 64 GiB), NVIDIA A10 enabled for passthrough
   (`nvidia.com/GA102GL_A10`). One control plane `16x40` with
   `gpu_devices.cp`, components `gpu-operator`, untagged VM network on `mgmt`
   with the lab DHCP: `nvidia.com/gpu` allocatable 1, product `NVIDIA-A10`,
   driver 615.71.09 (precompiled SLES 16.1), operator validator passed,
   `nvidia-smi` in a pod OK. A Kube-OVN overlay network with `natOutgoing` was
   tried first: the add-on runs Kube-OVN with `--non-primary-cni-mode=true`, so
   no host masquerade exists and VMs have no egress; the runner has no route to
   the build host status either. On overlay networks Harvester's webhook
   switches `bridge` interfaces to the `managedtap` binding.

## Sources

- Provider docs: https://github.com/harvester/terraform-provider-harvester/tree/master/docs
- Support matrix: https://github.com/harvester/docs/blob/main/docs/terraform/terraform-provider.md
- Image upload and export: https://github.com/harvester/docs/blob/main/docs/image/upload-image.md
- Networking: https://github.com/harvester/docs/tree/main/docs/networking
- VM load balancer: https://github.com/harvester/docs/blob/main/docs/networking/loadbalancer.md
- PCI passthrough: https://github.com/harvester/docs/blob/main/docs/advanced/addons/pcidevices.md
- vGPU: https://github.com/harvester/docs/blob/main/docs/advanced/vgpusupport.md
- Ignition platforms: https://github.com/coreos/ignition/blob/main/docs/supported-platforms.md
- elemental3 multi-node: https://github.com/SUSE/elemental/tree/main/examples/elemental/customize/multi-node
- elemental3 cloud enablement: https://github.com/SUSE/elemental/blob/main/docs/cloud-enablement.md
- endpoint-copier-operator: https://github.com/suse-edge/endpoint-copier-operator
- Earlier Harvester VM module: https://github.com/e-minguez/terraform-harvester-vm
