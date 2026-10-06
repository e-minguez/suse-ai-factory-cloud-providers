# `modules/exoscale`

Terraform module for a SUSE AI Factory cluster on Exoscale, in one zone: a
jumphost that builds the elemental image and registers it as a qcow2
template, the control planes as one instance pool behind a network load
balancer (Kubernetes API VIP and ingress), and any mix of worker and GPU pools
as standalone instances on one managed private network.

The module builds its own template: the jumphost runs `elemental customize
--type raw` in podman, converts the raw to qcow2 (virtual size grown to the
10 GiB minimum) and serves it over HTTP; `exoscale_template` registers it with
the MD5 the jumphost writes next to it. The template is in state, so
`terraform destroy` deletes it. The jumphost holds no Exoscale API key.

Platform behaviour and the reasons behind these choices:
[`docs/providers/exoscale.md`](../../docs/providers/exoscale.md) and
[ADR 008](../../docs/decisions/008-exoscale-module.md). Runnable root and
`deploy.sh`: [`examples/exoscale`](../../examples/exoscale/README.md).

Shared pieces: `modules/elemental-config` (rendered config, per-node Ignition,
`build_hash`), `modules/image-factory` (build script), `modules/rke2-ports`
(port tables). Common variables come from `modules/common/variables-common.tf`
through the `variables-common.tf` symlink; provider-only variables are in
`variables.tf`.

## Topology

```
        internet --> nlb :6443 (api_cidrs), :9345 (nodes), :80/:443 (ingress_cidrs)
                       |  targets: the control plane pool (NLB services take pools only)
        internet --> jumphost    the only SSH entry (admin_cidrs)
                       |
           +-----------+------------------------------+
     <cluster>-cp-<pool id>-<random>         <cluster>-<pool>-NN
     instance pool, anti-affinity group      standalone instances
     Traefik pinned here                     no inbound rules
           |                                          |
           +------ private network (vpc_cidr, DHCP, MTU 1500) ------+
```

Every node has a public IPv4: the NLB returns traffic from the members' public
interface, Ignition reads its config from the metadata service (which private
instances do not get), and egress uses it. Security groups are the only
filter and do not apply inside the private network, so SSH goes jumphost →
private address (`scripts/ssh.sh`).

Creation order:

```
1  private network, security groups, NLB   NLB address goes into the image
2  jumphost                                 builds the image, serves it on :80
3  template                                 terraform_data.image_served polls,
                                            data.http.image_md5, exoscale_template
4  control plane pool (size 1, init)        + NLB services; cp_init_ready waits for
   worker and GPU instances                   the API through the NLB
-- pass 2 (deploy.sh) ------------------------------------------------------
5  pool user_data -> join, size -> control_plane_count, close tcp/80
```

## Two passes

The control planes share one Ignition entry (a pool has one `user_data`). Only
the init configuration (`IS_INIT_NODE=true`) bootstraps a cluster, and it is
rendered only while `cp_initialized` is false, with the pool at size 1. Pass 2
sets `cp_initialized = true`: the pool switches to the join configuration and
scales to `control_plane_count`. Joining members reach the init member through
the NLB on 9345 (elemental derives the join URL from `network.apiVIP`). The
pool update is in place and only affects new members.

`deploy.sh` decides from state, not from its pin file: with the pool in state
it runs a single pass with `cp_initialized = true`. It aborts when a plan would
create or replace the pool of an initialized cluster.

## Nodes

- Control planes: `<cluster>-cp-<pool id>-<random>` (Exoscale names pool
  members; not `-NN`). `node-hostname.service` sets the hostname and the RKE2
  `node-name` from the metadata `local-hostname` before RKE2 starts.
- Pool members get their private NIC hot-plugged after boot:
  `wait-privnet.service` waits up to 300 s for the address inside `vpc_cidr`,
  then `write-node-ip.sh` pins RKE2 to it. RKE2 requires both units.
- Workers and GPU nodes: `<cluster>-<pool>-NN`, standalone, dynamic lease.
- `ignition.platform.id=exoscale`; per-node `user_data` limit 24576 bytes
  (32768 base64 characters at the API).

Both units ship through `elemental-config`'s `extra_butane_units` and
`extra_butane_files`, so other providers' images are unaffected.

## What triggers an image rebuild

`module.config.build_hash` is the only trigger: the rendered config files, the
release manifest, `elemental_image`, `core_platform_override`, the effective
`sysext_image_overrides`, `image_rebuild`, the factory script and the node
units. A new hash rotates `random_id.serve_path`, which replaces the jumphost
(its `user_data` would otherwise update in place without re-running
cloud-init), the template and every standalone node. The control plane pool
updates its template in place: existing members keep the old image until they
are replaced (evict one at a time, see `docs/scaling.md`).

- Anything moving the NLB address, SSH keys, password hashes, `components`,
  `aif_release` or `ingress_controller` rebuilds the image.
- `image_id` set (a template ID) skips the import; the jumphost is still created.
- `deploy_nodes = false` builds the image only.

## Availability and input checks

`data.external.api_check` runs `scripts/exoscale-api.sh` (signed reads, `curl`,
`jq`, `openssl`) and `terraform_data.api_check` fails the plan when an instance
type is not offered in the zone or not available to the organization (the
signed type list omits those), when a GPU pool uses a type without GPUs or a
worker pool one with GPUs, or when the instance, NLB or per-family GPU quota
has no room for what the next apply adds (resources this cluster already holds
are counted). Input checks are preconditions on `exoscale_private_network.this`:
`zones` at most one entry, `vpc_cidr` /16 to /26, `vpc_mtu` at most 1500,
`control_plane_count` at most 8 (anti-affinity group), `cluster_name` at most
27 characters (pool `instance_prefix`), pool `zone`, `placement` and `kind`.

## Provider-only variables

| Variable | Purpose |
|---|---|
| `exoscale_api_key`, `exoscale_api_secret` | Signed plan-time checks and the control plane member lookup; the example root also passes them to the provider |
| `cp_initialized` | Set by `deploy.sh` after pass 1 |
| `image_import_port_open` | Set by `deploy.sh` on pass 2; reset when a new template is registered |

`provider_details` output: `control_plane_pool_id`, `nlb_id`,
`private_network_id`, `security_group_ids`, `cp_initialized`.

## Inputs and outputs

Generated by `make docs`; do not edit between the markers.

<!-- BEGIN_TF_DOCS -->
## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| admin\_cidrs | CIDRs allowed to reach the jumphost and nodes over SSH. No default: an empty list locks everyone out. | `list(string)` | n/a | yes |
| aif\_release | AI Factory release: a manifest URL (http:// or https://), or a version X.Y.Z[-pre] resolved to the SUSE/aif tag aif-operator-<version>. | `string` | `"2.2.0"` | no |
| api\_cidrs | CIDRs allowed to reach the public Kubernetes API listener on 6443. Narrow it to keep kubectl access off the internet. | `list(string)` | <pre>[<br/>  "0.0.0.0/0"<br/>]</pre> | no |
| api\_host | DNS name of the RKE2 API, added to the API server certificate SANs. Null derives a provider default. | `string` | `null` | no |
| appco\_password | Application Collection password or token, paired with appco\_username. | `string` | `null` | no |
| appco\_registry | Registry host used by the Application Collection image pull secret. | `string` | `"dp.apps.rancher.io"` | no |
| appco\_username | Application Collection username. Required with local-path-provisioner or suse-storage; recommended with aif-operator so it can pull its workloads right after deployment. | `string` | `null` | no |
| cluster\_name | Prefix of resource names and node hostnames (<cluster\_name>-cp-NN, <cluster\_name>-<pool>-NN). | `string` | `"suse-ai-factory"` | no |
| components | AI Factory Helm charts to enable. Rendered in canonical order, not the order given. | `list(string)` | <pre>[<br/>  "rancher",<br/>  "gpu-operator",<br/>  "local-path-provisioner",<br/>  "aif-operator"<br/>]</pre> | no |
| control\_plane\_count | Number of control-plane nodes: 1 (single node, no etcd quorum) or odd and at least 3. Growing from 1 only adds nodes. | `number` | `3` | no |
| control\_plane\_disk\_size\_gb | Root disk size in GB of the control-plane nodes. Null uses the provider default; providers whose plans fix the disk reject a value. | `number` | `null` | no |
| control\_plane\_instance\_type | Machine type, flavor or plan of the control-plane nodes. Null uses the provider default (about 4 vCPU / 16 GiB). | `string` | `null` | no |
| control\_plane\_public\_ip | Give control-plane nodes a public IP. Not needed for access or egress on providers with NAT; providers that never assign one reject true. | `bool` | `false` | no |
| core\_platform\_override | Beta workaround: flatten the release manifest into a core platform manifest pinning these images; null disables it. See docs/workarounds.md. | <pre>object({<br/>    os_image_base      = string<br/>    os_image_iso       = string<br/>    kubernetes_version = string<br/>    kubernetes_image   = string<br/>  })</pre> | <pre>{<br/>  "kubernetes_image": "registry.suse.com/elemental/rke2/rke2-tar:1.35.6_rke2r1-9.1",<br/>  "kubernetes_version": "v1.35.6+rke2r1",<br/>  "os_image_base": "registry.suse.com/beta/uc/base-os-kernel-default:16.1-73.2",<br/>  "os_image_iso": "registry.suse.com/beta/uc/base-os-kernel-default-iso:16.1-73.3"<br/>}</pre> | no |
| cp\_initialized | The control plane pool's first member has bootstrapped the cluster. false renders the init configuration with pool size 1; true renders the join configuration and scales to control\_plane\_count. deploy.sh sets it after pass 1 (docs/decisions/008-exoscale-module.md). | `bool` | `false` | no |
| deploy\_nodes | Provision control-plane, worker and GPU nodes. false builds the image only and creates no nodes. | `bool` | `true` | no |
| elemental\_image | Container image that runs `elemental customize` on the build host. | `string` | `"registry.suse.com/beta/uc/elemental:3.1.0-6.5"` | no |
| exoscale\_api\_key | Exoscale API key for the signed plan-time checks and the control plane member lookup. The root module also passes it to the exoscale provider. | `string` | n/a | yes |
| exoscale\_api\_secret | Secret of exoscale\_api\_key. | `string` | n/a | yes |
| fips | Set cryptoPolicy: fips in install.yaml. Every node must be FIPS-ready. | `bool` | `false` | no |
| gpu\_driver\_repository | Registry path of the precompiled NVIDIA driver container. Experimental default; see docs/workarounds.md. | `string` | `"registry.opensuse.org/home/eminguez/branches/home/avicenzi/nvidia-for-bci-161/containerfile/third-party/nvidia"` | no |
| gpu\_driver\_version | NVIDIA driver branch of the precompiled driver container; must exist under gpu\_driver\_repository. | `string` | `"615"` | no |
| gpu\_pools | GPU worker pools keyed by pool name. instance\_type is the provider's type, flavor or plan; kind is vm or bare\_metal; fields a provider does not support must be null. | <pre>map(object({<br/>    instance_type = string<br/>    count         = optional(number, 1)<br/>    disk_size_gb  = optional(number)<br/>    zone          = optional(string)<br/>    public_ip     = optional(bool, false)<br/>    kind          = optional(string, "vm")<br/>    placement     = optional(string)<br/>  }))</pre> | `{}` | no |
| image\_disk\_size | Size of the raw image elemental builds (install.yaml raw.diskSize). | `string` | `"8G"` | no |
| image\_id | Existing image (AMI or snapshot) to boot instead of building one. Null builds the image. Providers with per-zone images use image\_ids. | `string` | `null` | no |
| image\_import\_port\_open | Allow tcp/80 from anywhere on the jumphost so Exoscale can fetch the qcow2 image. deploy.sh sets it to false on pass 2, once the template exists. | `bool` | `true` | no |
| image\_rebuild | Rebuild counter mixed into the image build hash. deploy.sh --rebuild bumps it in rebuild.auto.tfvars.json; do not set it by hand unless you know why. | `number` | `0` | no |
| ingress\_cidrs | CIDRs allowed to reach the ingress on 80/443, which serves the Rancher UI. Narrow it for clusters that are not public. | `list(string)` | <pre>[<br/>  "0.0.0.0/0"<br/>]</pre> | no |
| ingress\_controller | RKE2 ingress-controller setting. Only traefik adds a HelmChartConfig. | `string` | `"traefik"` | no |
| jumphost\_disk\_size\_gb | Root disk size in GB of the jumphost. Null uses the provider default; providers whose plans fix the disk reject a value. | `number` | `null` | no |
| jumphost\_image | OS image (AMI, image name or OS ID) of the jumphost. Null uses the provider default (an openSUSE Leap image). | `string` | `null` | no |
| jumphost\_instance\_type | Machine type, flavor or plan of the jumphost that builds the image and serves as SSH bastion. Null uses the provider default. | `string` | `null` | no |
| jumphost\_username | Login user of the jumphost. Empty makes the jumphost root-only. | `string` | `"suse"` | no |
| keep\_build\_artifacts | Keep the intermediate build artifacts (raw image, build disks) after the image is registered. No effect on vultr, which builds on the jumphost. | `bool` | `false` | no |
| node\_user\_password\_hash | Crypt hash for node\_username. | `string` | n/a | yes |
| node\_username | Unprivileged login account created on every node. | `string` | `"suse"` | no |
| nvidia\_api\_key | NVIDIA NGC API key. Optional, recommended with aif-operator; unset omits the nvidia credentials block. | `string` | `null` | no |
| nvidia\_username | NGC username paired with nvidia\_api\_key; NGC uses the literal $oauthtoken for API-key auth. | `string` | `"$oauthtoken"` | no |
| permit\_root\_ssh | Allow SSH logins as root and install ssh\_authorized\_keys for it. Debug toggle. | `bool` | `false` | no |
| rancher\_bootstrap\_password | Rancher initial admin password; a random one is generated when null. | `string` | `null` | no |
| rancher\_hostname | Hostname of the Rancher ingress. Null selects a provider-specific default. | `string` | `null` | no |
| region | Provider region or location. Required by providers that have no region default; the provider module checks it. | `string` | `null` | no |
| root\_password\_hash | Crypt hash for the root account (for example from `openssl passwd -6`). | `string` | n/a | yes |
| ssh\_authorized\_keys | SSH public keys for node\_username, and for root when permit\_root\_ssh is set. | `list(string)` | n/a | yes |
| suse\_registry\_password | SUSE registry password, paired with suse\_registry\_username. | `string` | `null` | no |
| suse\_registry\_username | SUSE registry username. Optional, set together with suse\_registry\_password; recommended with aif-operator. | `string` | `null` | no |
| suse\_storage\_nodes | Where the suse-storage (Longhorn) disks live: roles (control\_plane, worker for all worker\_pools, gpu for all gpu\_pools) and/or pool names, e.g. ["control\_plane", "storage"]. At least three such nodes are required. | `list(string)` | <pre>[<br/>  "control_plane"<br/>]</pre> | no |
| sysext\_image\_overrides | Beta workaround: per-extension OCI image overrides written into the release manifest, keyed by extension name. See docs/workarounds.md. | `map(string)` | <pre>{<br/>  "suse-storage": "registry.suse.com/beta/uc/longhorn:5.279-4.13"<br/>}</pre> | no |
| tags | Extra tags or labels on every resource that supports them. Keys must not use the elemental- prefix, which the module manages. | `map(string)` | `{}` | no |
| vpc\_cidr | IPv4 CIDR of the cluster network, from which subnets are derived; null uses the provider default. Must not overlap the RKE2 cluster (10.42.0.0/16) or service (10.43.0.0/16) CIDRs. | `string` | `null` | no |
| vpc\_mtu | MTU of the cluster network interfaces; the pod MTU is derived from it. Null uses the provider default. | `number` | `null` | no |
| worker\_pools | Worker pools without GPUs keyed by pool name, with the same fields as gpu\_pools. Hostnames are <cluster\_name>-<pool>-NN, so keys must not collide with gpu\_pools keys. | <pre>map(object({<br/>    instance_type = string<br/>    count         = optional(number, 1)<br/>    disk_size_gb  = optional(number)<br/>    zone          = optional(string)<br/>    public_ip     = optional(bool, false)<br/>    kind          = optional(string, "vm")<br/>    placement     = optional(string)<br/>  }))</pre> | `{}` | no |
| zones | Zone suffixes the cluster spans (for example ["a", "b", "c"]); control planes are spread round-robin. Empty uses the provider default; providers without zones accept at most one entry. | `list(string)` | `[]` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| api\_host | DNS name of the Kubernetes API; it is in the API server certificate SANs. |
| api\_vip | IPv4 of the network load balancer. |
| build\_status | Image import URL and the build hosts reachable via the jumphost while no template exists yet; null once it does. |
| cluster\_name | Cluster name. |
| egress\_ips | Public source IPs of cluster egress: every node egresses from its own public IP. |
| image | Image build ID and the template ID per zone; none while the template does not exist. |
| ingress\_endpoint | URL of the ingress listeners on the network load balancer. null when ingress\_controller is none. |
| jumphost | Jumphost addresses and login user (root when jumphost\_username is empty). |
| kubernetes\_api\_endpoint | Kubernetes API URL on api\_host, port 6443. |
| network | Private network CIDR, also the only subnet. |
| next\_steps | Post-deploy hints. |
| nodes | Cluster nodes keyed by hostname; control planes are the pool's current members. Empty when deploy\_nodes is false. |
| provider | Provider name, for tools that dispatch on it. |
| provider\_details | Exoscale-specific values: pool, load balancer, network and security group IDs, and the cp\_initialized pin deploy.sh keeps. |
| rancher\_bootstrap\_password | Rancher initial admin password. null when rancher is not in components. |
| rancher\_hostname | Hostname Rancher's ingress is configured for. null when rancher is not in components. |
| rancher\_url | Rancher UI URL. null when rancher is not in components. |
| region | Exoscale zone the cluster runs in. |
<!-- END_TF_DOCS -->

## Known gaps

- `public_ip` (pools) has no effect and `control_plane_public_ip` only decides
  whether `nodes` reports the control planes' public IPs: every node
  has a public IPv4 on this provider.
- Scaling the control plane down removes the oldest member first and leaves
  its etcd member behind; see `docs/scaling.md`.
- The control plane member lookup reads the private network's `leases`; if a
  member has none, its `private_ip` is null and `scripts/ssh.sh` cannot reach it
  through the jumphost.
- `keep_build_artifacts` has no effect: the image is built on the jumphost.
