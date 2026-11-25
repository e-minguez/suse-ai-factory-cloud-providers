# SUSE Harvester platform notes

Platform behaviour that decides how the Harvester module is built. Decision
record: [ADR 013](../decisions/013-harvester-module.md). Design and the checks
behind it: [plan](../plans/harvester.md). Items still open are listed at the
end.

## Limitations

- Existing networks only: `vpc_id` names a Harvester VM network
  (`<namespace>/<name>`); the module creates no network, cluster network or VLAN
  config.
- Harvester 1.8 or later (provider `harvester/harvester` `>= 1.8.0, < 2.0.0`).
- No public IPs: `control_plane_public_ip` and a pool `public_ip` must be false,
  `placement` null, `kind` `"vm"`, `zones` empty; each fails the plan.
- `admin_cidrs`, `api_cidrs` and `ingress_cidrs` are accepted and not enforced
  (see [Network](#network)).
- No cost estimate (on-premises) and no quota API: host CPU and memory capacity
  are not checked at plan.
- GPU passthrough is verified on control planes (`gpu_devices.cp`, one NVIDIA
  A10); GPU pools use the same mechanism and have not run on hardware.

## Prerequisites

- A Harvester cluster, version 1.8 or later, and a kubeconfig for it (below).
- An existing namespace for every object of the cluster (`harvester_namespace`).
  The module does not create it; a missing namespace fails the apply at the
  first create (the provider has no namespace data source).
- A VM network of type L2 VLAN or untagged with DHCP and egress to the internet
  from the physical network. VMs need `registry.suse.com`, `registry.rancher.com`
  and, for the default build host image, `download.opensuse.org`. Overlay
  networks (Kube-OVN) do not fit: the runner has no route into them, and in the
  `kubeovn-operator` add-on configuration Kube-OVN is a secondary CNI that
  installs no outgoing NAT on the hosts.
- Two free static IPv4 addresses inside the network's subnet, outside the DHCP
  range, for the API (`api_vip`) and the ingress (`ingress_vip`). Nothing at plan
  can detect an address that someone else uses without a lease.
- The runner machine must reach the network: Terraform polls the build status on
  the build host, the VIPs have to be reachable for kubectl and the browser, and
  `scripts/ssh.sh` connects to the nodes directly (no bastion).

### Kubeconfig and TLS

Download the kubeconfig from the Harvester UI: Support, Download KubeConfig. By
default the provider reads `KUBECONFIG` (then `~/.kube/config`), so nothing
about it is stored in tfvars; `harvester_kubeconfig_path` (a path, so the
content stays out of state) and `harvester_kubecontext` override that.

Harvester's default API certificate covers IP addresses only, so the hostname in
the downloaded kubeconfig fails verification. Either put the Harvester VIP in
the kubeconfig `server:` field:

```yaml
server: https://<harvester-vip>/k8s/clusters/local
```

or install a certificate for your hostname through the `ssl-certificates`
setting.

## Uploading the build host image

The build host needs an image with cloud-init, qemu-guest-agent and `zypper`. By
default the module downloads the openSUSE Leap 16.0 Minimal-VM Cloud qcow2
itself (`buildhost_image_url`, a `harvester_image` of source type `download`). To
provide the image another way, create it first and set
`jumphost_image = "<namespace>/<name>"`; the module then downloads nothing.

- **UI, URL:** Images, Create, Source Type `Download`, with the URL
  `https://download.opensuse.org/distribution/leap/16.0/appliances/Leap-16.0-Minimal-VM.x86_64-Cloud.qcow2`.
- **UI, file:** Images, Create, Source Type `Upload`, with the qcow2 on your
  workstation.
- **Manifest:**

  ```yaml
  apiVersion: harvesterhci.io/v1beta1
  kind: VirtualMachineImage
  metadata:
    name: leap-16-0-cloud
    namespace: <namespace>
  spec:
    displayName: leap-16-0-cloud
    sourceType: download
    url: https://download.opensuse.org/distribution/leap/16.0/appliances/Leap-16.0-Minimal-VM.x86_64-Cloud.qcow2
  ```

- **Disconnected clusters:** download the qcow2 elsewhere, upload the file
  through the UI, and set `jumphost_image = "<namespace>/<name>"`. The build host
  still needs a `zypper` repository and a registry it can reach (a mirror).

Images downloaded from Harvester since v1.5.5 are gzip-compressed; the module
only reads the images it creates itself.

## Passes: 1, and why

The image is exported from the volume the build host wrote, and the VIPs are
static inputs, so nothing depends on a created instance and `deploy.sh` is
single pass
([ADR 013](../decisions/013-harvester-module.md)).

## Images

1. A `harvester_image` of the build host image (download from
   `buildhost_image_url`, unless `jumphost_image` names an existing one).
2. A blank `harvester_volume` `image_target` (Block, `image_disk_size`) is
   attached to the build host as a second virtio disk.
3. The image factory builds the raw image and `dd`s it with `conv=fsync` to the
   only blank virtio disk at least as large as the raw (the provider sets no
   disk serial), then checks the GPT signature (8 GiB in 76 to 90 s).
4. The build writes `<build_id> <building|done|failed> <detail>` to a status
   file that `python3 -m http.server` serves on the build host (port 8080).
   `wait-for-image.sh` polls `http://<build_host_ip>:8080/status` and fails fast on
   `failed` (use `scripts/build-logs.sh`).
5. With `buildhost_power_off` (default `true`) the build host powers off once a
   request has read the `done` status (30 minutes at most), and
   `wait-for-image.sh` waits until the status URL stops answering (15 minutes at
   most; then it only warns). A failed build keeps it running for
   `scripts/build-logs.sh`. If an apply is interrupted after the power-off, the
   next apply waits for a status nobody serves: start the VM in Harvester (it
   serves the status again) or rebuild.
6. A `harvester_image` of source type `export-from-volume` turns the volume into
   the node image, named after `build_id`. It reached `Imported` in about 4
   minutes from a running build host (Step 0); export from the volume of the
   powered-off build host is the default path.

The node image is the size of the whole volume, so `image_disk_size` also bounds
the minimum node root disk. A new `build_id` uses a new volume: Harvester does
not attach a PVC another VM already uses. The image is rebuilt only when
`build_hash` changes; `image_id` (`<namespace>/<name>`) skips the chain.
Harvester gives each image its own StorageClass (`lh-<uuid>`).

## Network

- One NIC per node on `vpc_id`; DHCP from the physical network. `vpc_cidr` is
  required and must be the real subnet. `vpc_mtu` null means 1500; pod MTU is
  `vpc_mtu - 50`. `write-node-ip.sh` is a no-op (single NIC).
- VLAN networks have no security groups: `admin_cidrs`, `api_cidrs` and
  `ingress_cidrs` are not enforced. Filtering is the job of the network the VMs
  attach to.
- **Fixed MACs.** Each node has a MAC derived from cluster and node name
  (locally administered `02:` prefix), so it gets the same DHCP address across
  reboots. Leases can be short (10 minutes on the test network): a control plane
  that returns after its lease expired may get another address and break etcd
  membership. Create DHCP reservations by MAC (the MACs are in the VM specs) or
  use long leases.
- **VIPs.** `api_vip` and `ingress_vip` are static IPv4 addresses inside
  `vpc_cidr`, outside the DHCP range, distinct and neither the network nor the
  broadcast address. MetalLB (L2, in the image through `api_vip_mode =
  "managed"`) announces them and `endpoint-copier-operator` keeps 6443 and 9345
  behind the API VIP. The ingress VIP is a MetalLB pool for the ingress
  controller Service (`externalTrafficPolicy: Local`). The VIPs are on the nodes'
  own L2 segment, so there is no hairpin. Only MetalLB may own them: a move
  without gratuitous ARP leaves the gateway with the old MAC for minutes (7.5 in
  the test), and MetalLB sends gratuitous ARP.
- **Host spread is soft.** The provider adds Harvester's default preferred
  anti-affinity (`kubernetes.io/hostname`, against every VM with the
  `harvesterhci.io/creator` label), so VMs spread against all Terraform- and
  UI-created VMs, not per cluster. Control planes can share a host. The
  provider has no affinity fields; the module sets no `node_selector`, which
  would block live migration during Harvester upgrades.
- Hostnames: `api_host` defaults to `<api_vip>.sslip.io`; `rancher_hostname` and
  `ingress_domain` to names based on `<ingress_vip>.sslip.io`.

## Nodes

One `harvester_virtualmachine` per node, keyed by hostname (`<cluster>-cp-NN`,
`<cluster>-<pool>-NN`): EFI (secure boot off), q35, virtio disks, a bridge NIC
on `vpc_id`, root disk from the node image (on the image's own StorageClass;
`storage_class_name` applies to the image target volume and the images). Root disks are deleted with the VM. A new
node image replaces every node.

- **Sizes.** `*_instance_type` is `"<vcpu>x<memory_gib>"` (`"8x32"`). Defaults:
  control plane `"8x32"`, build host `"4x8"` (`jumphost_instance_type`); worker and
  GPU pools must set it.
- **user_data.** Plain Ignition JSON in a `harvester_cloudinit_secret` (NoCloud,
  key `userdata`), no gzip. The limit is 900000 bytes (Secret limit 1 MiB; tested
  up to 920429 bytes). Kernel command line `console=ttyS0
  ignition.platform.id=kubevirt`; Ignition 2.26 in the image reads the NoCloud
  disk.
- **Guest agent.** The Elemental base OS ships qemu-guest-agent; udev starts it
  when KubeVirt adds the agent port. Harvester reports node addresses, and
  apply waits for them (`wait_for_lease`, IP back about 80 s after a restart).
- **First boot takes 5 to 7 minutes** from VM create to SSH: about 3 minutes to
  attach the root volume (transient `FailedAttachVolume` events are normal),
  then the recovery autoinstall, a reboot and Ignition.
- **Build host** (Terraform `harvester_virtualmachine.buildhost`, VM
  `<cluster>-buildhost`, label `elemental-role=builder`; sized and configured by
  the common `jumphost_*` variables, reported in the common `jumphost` output).
  It exists
  while an image is built (not with `image_id`) and powers off afterwards
  (`buildhost_power_off`); the stopped VM stays in state until the next build
  replaces it. `jumphost.public_ip` is null with `buildhost_power_off` (the
  apply that powers it off would otherwise report the old address), else its
  VLAN address (`private_ip` is the same).
- **Node addresses** are DHCP leases: `nodes[*].private_ip`. There is no
  bastion: with no build host address, `scripts/ssh.sh` and
  `scripts/kubeconfig.sh` connect to the nodes directly, so the machine running
  them must reach the VLAN (as it must for the VIPs).
  `provider_details.macs` lists the fixed MACs for DHCP reservations.

## Storage latency and etcd

etcd fsyncs on every commit and needs low write latency. The default
`harvester-longhorn` class keeps 3 replicas on other hosts, so each fsync
crosses the network three times; on HDD-backed clusters etcd requests took
about 1.5 s, the API server reported etcd not ready, and no chart (MetalLB
included) was installed. In order of preference:

1. **A single-replica StorageClass with data locality** for node disks
   (`storage_class_name`): `numberOfReplicas: "1"`, `dataLocality:
   best-effort`, and `migratable: "true"` to keep live migration. RKE2
   replicates etcd across control planes, so Longhorn copies add latency, not
   safety. Node disks use the image's StorageClass, so the image is rebuilt.
   With `migratable: "false"` the build volume and node disks are
   `ReadWriteOnce` (Longhorn serves `ReadWriteMany` through NFS otherwise,
   which a VM block disk cannot use), so those VMs cannot live-migrate.
   `node_storage_classes` sets a class per node group (`cp`, a pool key, or
   `buildhost` for the downloaded build host image): for example `{ cp = "yolo" }`
   puts control planes on a single-replica class and keeps agents on
   replicated Longhorn. Harvester clones images only to encrypt them, so each
   extra class gets its own export of the node image (about 4 minutes, in
   parallel); the build volume stays on `storage_class_name`.
2. **`disk_cache_mode`** (`none`, `writethrough`, `writeback`): KubeVirt cache
   mode of node root disks. `writeback` speeds up ordinary writes but keeps
   guest flushes, so etcd fsync latency barely changes. KubeVirt has no
   `unsafe` mode.
3. **`etcd_unsafe_no_fsync = true` — DANGEROUS.** etcd skips fsync
   (`--unsafe-no-fsync`), which is what libvirt `cache=unsafe` did for it. A
   host crash or power loss can corrupt etcd and lose the cluster. Every plan
   warns while it is set. Only for throwaway clusters on disks too slow for
   etcd.

### Slow HDD hosts

On HDD-only hosts behind a RAID controller without an active write cache
(for example a flash-backed module with no backup power, which the controller
reports as permanently disabled), every write waits for the platter: 4 KiB
synchronous writes took about 21 ms. Host settings outside this module that
helped, all for lab clusters only:

- **Drive write cache** on the physical disks (HPE: `ssacli ctrl slot=<n>
  modify drivewritecache=enable`): 4 KiB synchronous writes went from about
  21 ms to 1.6 ms. A power loss can lose the writes still in the drive cache.
- **`mq-deadline`** on the RAID logical volumes and `none` on the Longhorn
  iSCSI devices (`sdc` and up, one per attached volume), instead of `bfq`.
- **More write buffering**: `vm.dirty_background_ratio=10`,
  `vm.dirty_ratio=40`, `vm.dirty_expire_centisecs=6000`, together with
  `disk_cache_mode = "writeback"`.

Persist the scheduler and sysctl settings with a Harvester `CloudInit`
resource (udev rule plus `sysctl` stage). With those host settings, a
single-replica class for every node disk, `disk_cache_mode = "writeback"` and
`etcd_unsafe_no_fsync = true`, a 3 control plane + 1 agent cluster had all
nodes joined about 9 minutes after etcd started. Without them, the same cluster
with agents on 3-replica Longhorn stalled with the control plane waiting on
disk about 40 % of the time.

## GPUs

GPU pools use PCI passthrough through the `pcidevices-controller` add-on (off by
default). Enable the add-on and `passthrough_enabled` on the devices
(`harvester_pcidevice` is cluster-scoped and not managed by the module). Set
`gpu_devices` for every `gpu_pools` key; the reserved key `cp` gives every
control plane the devices (single-node GPU clusters):

```hcl
gpu_devices = {
  gpu = { device_name = "nvidia.com/GA102GL_A10", count = 1 }
  cp  = { device_name = "nvidia.com/GA102GL_A10", count = 1 }
}
```

`device_name` is the KubeVirt host device resource name, `count` the devices per
node. The add-on binds an enabled device to `vfio-pci` on its host and
advertises it to KubeVirt as that resource (`kubectl get pcidevices` shows it);
each `host_device` entry requests one, so the scheduler places the VM on the
host that has a free device and the guest sees a plain PCI GPU. The GPU operator
then installs the driver in the guest as on any other provider.

- **Verified** with one NVIDIA A10 (`nvidia.com/GA102GL_A10`) on a single
  control plane (`cp`), Harvester 1.10.0-rc3: `nvidia.com/gpu` allocatable 1,
  operator validations passed, `nvidia-smi` in a pod shows the A10 with the
  precompiled SLES 16.1 driver.
- **Memory.** A VM with a passthrough device has all of its memory pinned on the
  host, regardless of Harvester's memory overcommit. Size GPU nodes to the free
  host memory (a `16x40` node ran on a 64 GiB host). Host capacity is not
  checked at plan.
- A device belongs to one VM at a time: on a host with a single GPU, a
  replacement node cannot start while the old one holds it, and an image rebuild
  runs the build host next to the pinned node. Destroy first there.

### Several hosts and device models

- **One resource name per model.** The resource name comes from the PCI vendor
  and device ID, so every enabled A10 on every host is
  `nvidia.com/GA102GL_A10`, and an L40S has its own name. List them with
  `kubectl get pcidevices -o custom-columns=NODE:.status.nodeName,ADDR:.status.address,RESOURCE:.status.resourceName`
  and `kubectl get pcideviceclaims` (enabled ones).
- **The scheduler picks the host and the device.** The module sets no node
  selector or PCI address: a node lands on any host with `count` free devices of
  its resource, and KubeVirt picks which ones. `count = 2` needs two free
  devices on the same host. A pool's nodes prefer different hosts (soft spread,
  see [Network](#network)).
- **One model per node group.** Each `gpu_devices` entry has a single
  `device_name`. Different models are different pools ([example 3](#examples)).
- **Only what is enabled counts.** Devices without passthrough enabled are not
  advertised; enabling is per device and outside the module. Nothing checks
  free devices at plan: a node without a free device stays unscheduled (VM pod
  `Pending`, `Insufficient <resource>`) until the apply times out.
- `device_name` is any KubeVirt host device resource, but the image only has
  the NVIDIA stack: GPUs are the supported case.

### Examples

Node groups and their `gpu_devices` keys: control planes are `cp`, each
`gpu_pools` key is its own group, `worker_pools` never get devices. Device names
are examples; read yours from `kubectl get pcidevices`.

1. **One GPU node** (inference in a box): the single control plane takes the GPU.

   ```hcl
   control_plane_count         = 1
   control_plane_instance_type = "16x64"
   gpu_devices = {
     cp = { device_name = "nvidia.com/GA102GL_A10", count = 1 }
   }
   ```

2. **Control planes, CPU workers and GPU workers.** Three control planes and two
   workers without devices; two GPU nodes with one A10 each, on hosts that
   have a free A10.

   ```hcl
   control_plane_count         = 3
   control_plane_instance_type = "8x32"
   worker_pools = {
     wrk = { instance_type = "8x32", count = 2 }
   }
   gpu_pools = {
     gpu = { instance_type = "16x64", count = 2 }
   }
   gpu_devices = {
     gpu = { device_name = "nvidia.com/GA102GL_A10", count = 1 }
   }
   ```

3. **Two GPU models.** As 2, with a second GPU pool whose node takes two L40S
   from one host. Each pool lands only on hosts with its model.

   ```hcl
   gpu_pools = {
     a10  = { instance_type = "16x64", count = 2 }
     l40s = { instance_type = "32x128", count = 1 }
   }
   gpu_devices = {
     a10  = { device_name = "nvidia.com/GA102GL_A10", count = 1 }
     l40s = { device_name = "nvidia.com/AD102GL_L40S", count = 2 }
   }
   ```

4. **GPUs on the control planes too.** `cp` applies to every control plane, so
   three control planes need three free devices; here the GPU pool also
   exists, and both groups draw from the same A10s (five in total).

   ```hcl
   control_plane_count         = 3
   control_plane_instance_type = "16x64"
   gpu_pools = {
     gpu = { instance_type = "16x64", count = 2 }
   }
   gpu_devices = {
     cp  = { device_name = "nvidia.com/GA102GL_A10", count = 1 }
     gpu = { device_name = "nvidia.com/GA102GL_A10", count = 1 }
   }
   ```

The plan rejects a `gpu_pools` key with nodes but no `gpu_devices` entry, and a
`gpu_devices` key that is neither `cp` nor a `gpu_pools` key. Changing
`gpu_devices` changes the VM spec of that group's nodes; check the `deploy.sh`
plan for replacements.

NVIDIA vGPU (SR-IOV, MIG) needs a vGPU host licence and the vGPU guest driver,
which the precompiled datacenter driver override does not cover: not supported.

## Variables and tfvars layering

Provider-only module variables: `harvester_namespace`, `vpc_id`, `api_vip`,
`ingress_vip`, `storage_class_name`, `buildhost_image_url`, `gpu_devices`. Root
only: `harvester_kubeconfig_path`, `harvester_kubecontext`. `region` is a
free-form label (`"harvester"`).

Put what every cluster shares in `common-harvester.tfvars`:

```hcl
# harvester_kubeconfig_path = "~/.kube/harvester.yaml"   # optional: else KUBECONFIG
harvester_namespace       = "<namespace>"
vpc_id                    = "<network-namespace>/<network-name>"
vpc_cidr                  = "<network subnet>"
```

and the VIPs per cluster in its `terraform.tfvars` (`api_vip`, `ingress_vip`;
every cluster of a multi-cluster shape needs its own pair).

## Cost estimate

Not available: Harvester is on-premises, `tools/cost` has no harvester provider.

## Leftover check

```bash
tools/leftovers/harvester.sh <cluster_name> --namespace <ns> [--kubeconfig <path>] [--kubecontext <ctx>]
```

Read-only (`kubectl` with the kubeconfig and namespace). It lists objects
labelled `elemental-cluster=<cluster_name>` in the namespace: virtual machines,
persistent volume claims, virtual machine images and secrets. `deploy.sh
--destroy` prints the command and never runs it.

## Operational limits

- An image cannot be deleted while a PVC created from it exists; root disks are
  `auto_delete`.
- The build status file is served without authentication on port 8080 while the
  build host runs: anyone who reaches the VLAN can read it (progress only).

## Still open

- End-to-end run on the test cluster (see the
  [checklist](../e2e-checklist.md#harvester)).
- GPU pools (`gpu_pools` with `gpu_devices`) on hardware; control-plane GPUs
  are verified.
- elemental3 [SUSE/elemental#487](https://github.com/SUSE/elemental/issues/487):
  secondary servers retry the RKE2 install when the VIP is announced early; joins
  may be slow.
- Per-cluster host anti-affinity needs a provider feature (upstream request).
- Static node addresses in Ignition (instead of DHCP reservations).
- Creating networks (cluster network, VLAN config, VM network) from the module.
- Destroy or rebuild can fail once with "image in use" while the deleted VMs'
  root volumes are still being removed; run it again.
- Root volumes created from the VM spec carry no `elemental-*` labels, so the
  leftover check does not list a leaked root volume.
- The ingress pool selects the nginx Service by `app.kubernetes.io/name`
  (`rke2-ingress-nginx` or `ingress-nginx`); confirm at the first nginx run.

## Sources

- [Harvester Terraform provider](https://github.com/harvester/terraform-provider-harvester/tree/master/docs)
- [Upload and export images](https://github.com/harvester/docs/blob/main/docs/image/upload-image.md)
- [PCI passthrough](https://github.com/harvester/docs/blob/main/docs/advanced/addons/pcidevices.md)
- [Ignition supported platforms](https://coreos.github.io/ignition/supported-platforms/)
- [elemental3 cloud enablement](https://github.com/SUSE/elemental/blob/main/docs/cloud-enablement.md)
