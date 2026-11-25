# SUSE AI Factory on SUSE Harvester: example

Single-cluster root for [`modules/harvester`](../../modules/harvester): VMs on an
existing Harvester VM network, a build host that builds the Elemental image and powers
off, and the node image exported from a volume. `deploy.sh` runs it in one pass.

**Status:** single-node and HA end-to-end runs passed (Harvester 1.8.2). `deploy_nodes = false`
stops after the image. GPU passthrough (`gpu_devices`) is verified on a control plane
(NVIDIA A10, Harvester 1.10.0-rc3); GPU pools have not run on hardware. How devices
are matched to hosts: [provider notes](../../docs/providers/harvester.md#gpus).

## Prerequisites

- Harvester 1.8 or later; Terraform 1.16.5 or later (or OpenTofu, experimental), `jq`, `curl`, `ssh`.
- A kubeconfig of the Harvester cluster, read from `KUBECONFIG` (then
  `~/.kube/config`) unless `harvester_kubeconfig_path` sets a path. Its server URL
  must verify against the kubeconfig CA: with a self-signed certificate that has
  IP SANs only, use the IP URL in `server:` or install a certificate in the `ssl-certificates` setting.
- An existing namespace (`harvester_namespace`) and VM network (`vpc_id`, `<namespace>/<name>`)
  with DHCP and egress; `vpc_cidr` is its subnet. The machine that runs `deploy.sh` must
  reach that network (the build status, the VIPs and SSH go through it).
- Two unused static addresses outside the DHCP range for `api_vip` and `ingress_vip`
  (different for every cluster).
- Two different `openssl passwd -6` hashes: `root_password_hash` and
  `node_user_password_hash`.
- `ssh_authorized_keys` (at least one) and `admin_cidrs` (not enforced on VLAN networks).
- Registry credentials: see [Registry credentials](../../README.md#registry-credentials).

```hcl
# ../common-harvester.tfvars
# harvester_kubeconfig_path = "/home/<you>/.kube/harvester.yaml"   # optional: else KUBECONFIG
harvester_namespace       = "<namespace>"
vpc_id                    = "harvester-public/vlan-2006"
vpc_cidr                  = "10.114.128.0/25"
```

## Deploy

```bash
cp terraform.tfvars.example terraform.tfvars   # edit it
./deploy.sh
```

The build host downloads the Leap 16.0 image (unless `jumphost_image` names one) and builds
for 30 to 60 minutes; follow it with `../../scripts/build-logs.sh -C .`. Terraform waits for the
`done` state on `http://<build host>:8080/status`, the build host powers off
(`buildhost_power_off`), then Harvester exports the volume as the node image. The first boot of a node takes 5 to 7 minutes.

Instance types are `<vcpu>x<memory_gib>`, for example `8x32`. Node addresses come from the
guest agent (`nodes[*].private_ip`); `provider_details.macs` has their MACs for DHCP reservations.

## End-to-end runbook

Tfvars layering, later wins: `../common-all.tfvars` (admin_cidrs, password
hashes, ssh keys, registry credentials, `aif_release`), `../common-harvester.tfvars`
(kubeconfig, namespace, network, `vpc_cidr`), then `terraform.tfvars` (cluster values:
VIPs, `gpu_pools`, `gpu_devices`, `worker_pools`, `control_plane_count`).

```bash
./deploy.sh                                   # image and nodes in one pass
./deploy.sh --rebuild                         # force a new image
```

Checks, from this directory (the user runs them):

```bash
# 1. Image imported
terraform output -json image | jq .
kubectl --kubeconfig "$HARVESTER_KUBECONFIG" -n <namespace> get virtualmachineimages.harvesterhci.io

# 2. VMs and their MACs
terraform output -json provider_details | jq .macs
kubectl --kubeconfig "$HARVESTER_KUBECONFIG" -n <namespace> get vm,vmi -l elemental-cluster=<cluster_name>

# 3. Kubeconfig and Ready nodes (needs the node address: see the note above)
../../scripts/kubeconfig.sh -C . --wait -o ~/.kube/harvester-aif.yaml
kubectl --kubeconfig ~/.kube/harvester-aif.yaml get nodes -o wide

# 4. VIPs answer
curl -k https://<api_vip>:6443/version
curl -k https://<ingress_vip>

# 5. Rancher
terraform output -raw rancher_url
terraform output -raw rancher_bootstrap_password

# 6. SSH straight to a node (no bastion)
../../scripts/ssh.sh -C . <cluster>-cp-01
```

Destroy with `./deploy.sh --destroy`; it prints the read-only leftover check
(`tools/leftovers/harvester.sh`).
