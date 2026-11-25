# `modules/oci`

Terraform module for a SUSE AI Factory cluster on Oracle Cloud (OCI): a VCN
with a public and a private subnet, a network load balancer on a reserved
public IP (Kubernetes API VIP and ingress), a jumphost that builds the
elemental image, and the custom image imported from Object Storage. This
version stops at the imported image: the nodes (control plane, agents and load
balancer backends) follow, so `deploy_nodes = true` fails the plan.

The module builds its own image: the jumphost (Oracle Linux 9) runs `elemental
customize --type raw` in podman, converts the raw to qcow2 and uploads it
through write-only pre-authenticated requests, so it holds no OCI credential.
`oci_core_image` imports it (PARAVIRTUALIZED) and a capability schema sets
`Compute.Firmware = UEFI_64`. The image is in state, so `terraform destroy`
deletes it.

Platform behaviour and the reasons behind these choices:
[`docs/providers/oci.md`](../../docs/providers/oci.md) and
[ADR 012](../../docs/decisions/012-oci-module.md). Runnable root and
`deploy.sh`: [`examples/oci`](../../examples/oci/README.md).

Shared pieces: `modules/elemental-config` (rendered config, per-node Ignition,
`build_hash`), `modules/image-factory` (build script), `modules/rke2-ports`
(port tables). Common variables come from `modules/common/variables-common.tf`
through the `variables-common.tf` symlink; provider-only variables are in
`variables.tf`.

## Topology

```
        internet --> nlb (reserved IP) :6443 (api_cidrs), :9345 (NAT address), :80/:443 (ingress_cidrs)
        internet --> jumphost    the only SSH entry (admin_cidrs)
                       |
                 public subnet  | private subnet (nodes, NAT gateway egress)
                       +--------------- VCN (vpc_cidr, MTU 9000) ---------------+
```

Creation order (one pass):

```
1  VCN, subnets, gateways, NSGs, reserved IP, NLB   address goes into the image
2  bucket, PARs, jumphost                            builds and uploads the qcow2
3  terraform_data.image_ready                        polls the done marker
4  oci_core_image, capability schema                 UEFI; GPU shape management
```

## What triggers an image rebuild

`build_hash` from `elemental-config` only: rendered config, release manifest,
elemental image, overrides and the factory script hash. A new hash changes the
qcow2 name, the PARs and the image, and replaces the jumphost.

## Availability and input checks

Preconditions on `terraform_data.input_checks` (shape syntax, zones, CIDR,
nodes, existing network) and `terraform_data.limits_check` (shapes offered, service limits).
Details: [`docs/providers/oci.md`](../../docs/providers/oci.md#quota-and-availability).

## Provider-only variables

`oci_tenancy_ocid` and `oci_compartment_ocid`. `vpc_id`, `public_subnet_id`
and `private_subnet_id` deploy into an existing VCN
([docs/providers/oci.md](../../docs/providers/oci.md#existing-network)). The root module configures the
`oci` provider and its API-key credentials.

## Inputs and outputs

<!-- BEGIN_TF_DOCS -->
## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| admin\_cidrs | CIDRs allowed to reach the jumphost and nodes over SSH. No default: an empty list locks everyone out. | `list(string)` | n/a | yes |
| aif\_release | AI Factory release: a manifest URL (http:// or https://), or a version X.Y.Z[-pre] resolved to the SUSE/aif tag aif-operator-<version>. | `string` | `"2.4.0"` | no |
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
| deploy\_nodes | Provision control-plane, worker and GPU nodes. false builds the image only and creates no nodes. | `bool` | `true` | no |
| elemental\_image | Container image that runs `elemental customize` on the build host. | `string` | `"registry.suse.com/beta/uc/elemental:3.1.0-6.5"` | no |
| etcd\_unsafe\_no\_fsync | DANGEROUS: disables fsync in etcd (etcd --unsafe-no-fsync), so a host crash or power loss can corrupt etcd and lose the cluster. Only for throwaway clusters on disks too slow for etcd. | `bool` | `false` | no |
| extra\_manifests\_dir | Directory of Kubernetes manifests (*.yaml, *.yml) to bundle into the Elemental image. Applied once at first boot. | `string` | `null` | no |
| fips | Set cryptoPolicy: fips in install.yaml. Every node must be FIPS-ready. | `bool` | `false` | no |
| gpu\_driver\_repository | Registry path of the precompiled NVIDIA driver container. Experimental default; see docs/workarounds.md. | `string` | `"registry.opensuse.org/home/eminguez/branches/home/avicenzi/nvidia-for-bci-161/containerfile/third-party/nvidia"` | no |
| gpu\_driver\_version | NVIDIA driver branch of the precompiled driver container; must exist under gpu\_driver\_repository. | `string` | `"615"` | no |
| gpu\_pools | GPU worker pools keyed by pool name. instance\_type is the provider's type, flavor or plan; kind is vm or bare\_metal; fields a provider does not support must be null. | <pre>map(object({<br/>    instance_type = string<br/>    count         = optional(number, 1)<br/>    disk_size_gb  = optional(number)<br/>    zone          = optional(string)<br/>    public_ip     = optional(bool, false)<br/>    kind          = optional(string, "vm")<br/>    placement     = optional(string)<br/>  }))</pre> | `{}` | no |
| image\_disk\_size | Size of the raw image elemental builds (install.yaml raw.diskSize). | `string` | `"8G"` | no |
| image\_id | Existing image (AMI or snapshot) to boot instead of building one. Null builds the image. Providers with per-zone images use image\_ids. | `string` | `null` | no |
| image\_rebuild | Rebuild counter mixed into the image build hash. deploy.sh --rebuild bumps it in rebuild.auto.tfvars.json; do not set it by hand unless you know why. | `number` | `0` | no |
| ingress\_cidrs | CIDRs allowed to reach the ingress on 80/443, which serves the Rancher UI. Narrow it for clusters that are not public. | `list(string)` | <pre>[<br/>  "0.0.0.0/0"<br/>]</pre> | no |
| ingress\_controller | RKE2 ingress-controller setting. Only traefik adds a HelmChartConfig. | `string` | `"traefik"` | no |
| ingress\_domain | A domain with a wildcard DNS record (`*.<domain>`) pointing at the ingress: a CNAME to the load balancer DNS name on aws, an A record to the ingress IP elsewhere. Hostnames become rancher.<domain>, obs.<domain> and neuvector.<domain>; null keeps the defaults. | `string` | `null` | no |
| jumphost\_disk\_size\_gb | Root disk size in GB of the jumphost. Null uses the provider default; providers whose plans fix the disk reject a value. | `number` | `null` | no |
| jumphost\_image | OS image (AMI, image name or OS ID) of the jumphost. Null uses the provider default (an openSUSE Leap image). | `string` | `null` | no |
| jumphost\_instance\_type | Machine type, flavor or plan of the jumphost that builds the image and serves as SSH bastion. Null uses the provider default. | `string` | `null` | no |
| jumphost\_username | Login user of the jumphost. Empty makes the jumphost root-only. | `string` | `"suse"` | no |
| keep\_build\_artifacts | Keep the intermediate build artifacts (raw image, build disks) after the image is registered. No effect on vultr, which builds on the jumphost, nor on gcp, which keeps the build disk and snapshot until the next build or destroy. | `bool` | `false` | no |
| node\_user\_password\_hash | Crypt hash for node\_username. | `string` | n/a | yes |
| node\_username | Unprivileged login account created on every node. | `string` | `"suse"` | no |
| nvidia\_api\_key | NVIDIA NGC API key. Optional, recommended with aif-operator; unset omits the nvidia credentials block. | `string` | `null` | no |
| nvidia\_username | NGC username paired with nvidia\_api\_key; NGC uses the literal $oauthtoken for API-key auth. | `string` | `"$oauthtoken"` | no |
| observability\_admin\_password | SUSE Observability admin password; a random one is generated when null. | `string` | `null` | no |
| observability\_allowed\_origins | Extra CORS origins allowed by the SUSE Observability server, for example remote Rancher URLs. The local Rancher URL is added automatically. | `list(string)` | `[]` | no |
| observability\_bootstrap\_token | SUSE Observability service token used by agents and the Rancher plugin. Generated when null with observability-server; required for observability-agent and observability-plugin without a local server. | `string` | `null` | no |
| observability\_ca\_pem | PEM CA certificate of the remote SUSE Observability server (the observability output ca\_pem). Required with observability\_server\_url. | `string` | `null` | no |
| observability\_hostname | Hostname of the SUSE Observability ingress (observability-server). Null selects an sslip.io name from the ingress address. | `string` | `null` | no |
| observability\_license\_key | SUSE Observability license key. Required with observability-server. | `string` | `null` | no |
| observability\_opensearch\_credentials | OpenSearch username and password for the collector elasticsearch receiver. Null disables the receiver. | <pre>object({<br/>    username = string<br/>    password = string<br/>  })</pre> | `null` | no |
| observability\_server\_url | HTTPS URL of a remote SUSE Observability server. Required for observability-agent and observability-plugin without observability-server; must be null with it. | `string` | `null` | no |
| observability\_sizing\_profile | SUSE Observability sizing profile (trial, 10-nonha, 20-nonha, 50-nonha, 100-nonha, 150-ha, 250-ha, 500-ha or 4000-ha). Used with observability-server. | `string` | `"trial"` | no |
| observability\_suse\_ai\_namespace | Namespace of the SUSE AI workloads whose metrics the observability-agent collector scrapes. | `string` | `"suse-private-ai"` | no |
| oci\_compartment\_ocid | OCID of the compartment that holds every resource of the cluster. | `string` | n/a | yes |
| oci\_tenancy\_ocid | OCID of the tenancy; its availability domains are resolved from it. | `string` | n/a | yes |
| permit\_root\_ssh | Allow SSH logins as root and install ssh\_authorized\_keys for it. Debug toggle. | `bool` | `false` | no |
| private\_subnet\_id | Existing regional subnet of vpc\_id that routes 0.0.0.0/0 to a NAT gateway: nodes. Its NAT address becomes the cluster egress IP. Required with vpc\_id. | `string` | `null` | no |
| public\_subnet\_id | Existing regional subnet of vpc\_id that allows public IPs and routes 0.0.0.0/0 to an internet gateway: jumphost and network load balancer. Required with vpc\_id. | `string` | `null` | no |
| rancher\_bootstrap\_password | Rancher initial admin password; a random one is generated when null. | `string` | `null` | no |
| rancher\_hostname | Hostname of the Rancher ingress. Null selects a provider-specific default. | `string` | `null` | no |
| region | Provider region or location. Required by providers that have no region default; the provider module checks it. | `string` | `null` | no |
| root\_password\_hash | Crypt hash for the root account (for example from `openssl passwd -6`). | `string` | n/a | yes |
| security\_admin\_password | NeuVector admin password for the security-management and security-downstream components; a random one is generated when null. | `string` | `null` | no |
| security\_hostname | Hostname of the NeuVector Manager ingress (security-management). Null selects an sslip.io name from the ingress address. | `string` | `null` | no |
| security\_join\_token | NeuVector federation join token (a lowercase UUID). Required with security-downstream; generated when null with security-management. | `string` | `null` | no |
| security\_primary\_endpoint | Federation endpoint of the primary NeuVector cluster as host or host:port (port defaults to 443). Required with security-downstream. | `string` | `null` | no |
| security\_rancher\_url | Rancher URL (https://...) used for NeuVector Rancher SSO. Null uses the local Rancher when rancher is enabled, otherwise SSO is off. | `string` | `null` | no |
| ssh\_authorized\_keys | SSH public keys for node\_username, and for root when permit\_root\_ssh is set. | `list(string)` | n/a | yes |
| suse\_registry\_password | SUSE registry password, paired with suse\_registry\_username. | `string` | `null` | no |
| suse\_registry\_username | SUSE registry username. Optional, set together with suse\_registry\_password; recommended with aif-operator. | `string` | `null` | no |
| suse\_storage\_nodes | Where the suse-storage (Longhorn) disks live: roles (control\_plane, worker for all worker\_pools, gpu for all gpu\_pools) and/or pool names, e.g. ["control\_plane", "storage"]. At least three such nodes are required. | `list(string)` | <pre>[<br/>  "control_plane"<br/>]</pre> | no |
| sysext\_image\_overrides | Beta workaround: per-extension OCI image overrides written into the release manifest, keyed by extension name. See docs/workarounds.md. | `map(string)` | <pre>{<br/>  "suse-storage": "registry.suse.com/beta/uc/longhorn:5.279-4.13"<br/>}</pre> | no |
| tags | Extra tags or labels on every resource that supports them. Keys must not use the elemental- prefix, which the module manages. | `map(string)` | `{}` | no |
| vpc\_cidr | IPv4 CIDR of the cluster network, from which subnets are derived; null uses the provider default. Must not overlap the RKE2 cluster (10.42.0.0/16) or service (10.43.0.0/16) CIDRs. | `string` | `null` | no |
| vpc\_id | OCID of an existing VCN to deploy into instead of creating one. Requires public\_subnet\_id and private\_subnet\_id; vpc\_cidr must be null or one of the VCN CIDR blocks. | `string` | `null` | no |
| vpc\_mtu | MTU of the cluster network interfaces; the pod MTU is derived from it. Null uses the provider default. | `number` | `null` | no |
| worker\_pools | Worker pools without GPUs keyed by pool name, with the same fields as gpu\_pools. Hostnames are <cluster\_name>-<pool>-NN, so keys must not collide with gpu\_pools keys. | <pre>map(object({<br/>    instance_type = string<br/>    count         = optional(number, 1)<br/>    disk_size_gb  = optional(number)<br/>    zone          = optional(string)<br/>    public_ip     = optional(bool, false)<br/>    kind          = optional(string, "vm")<br/>    placement     = optional(string)<br/>  }))</pre> | `{}` | no |
| zones | Zones the cluster spans, suffixes or full names as the provider expects (for example ["a", "b"] or ["europe-west4-a"]); control planes are spread round-robin. Empty uses the provider default; providers without zones accept at most one entry. | `list(string)` | `[]` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| api\_host | DNS name of the Kubernetes API; it is in the API server certificate SANs. |
| api\_vip | Reserved public IPv4 of the network load balancer. |
| build\_status | Object Storage location of the qcow2 and the build host reachable via the jumphost while no image exists yet; null once it does. |
| cluster\_name | Cluster name. |
| egress\_ips | Public source IPs of cluster egress: the NAT gateway address of the private subnet. |
| image | Image build ID and the image OCID per region; none while the image does not exist. |
| ingress\_endpoint | URL of the ingress listeners on the network load balancer. null when ingress\_controller is none. |
| jumphost | Jumphost addresses and login user (root when jumphost\_username is empty). The addresses are null when image\_id is set and deploy\_nodes is false: no jumphost exists then. |
| kubernetes\_api\_endpoint | Kubernetes API URL on api\_host, port 6443. |
| network | VCN CIDR and the public and private subnet CIDRs. |
| next\_steps | Post-deploy hints. |
| nodes | Cluster nodes keyed by hostname. Empty when deploy\_nodes is false. |
| observability | SUSE Observability URL, CA certificate and OTLP endpoints. Null when observability-server is not enabled. |
| observability\_credentials | SUSE Observability admin password and bootstrap token. Null when observability-server is not enabled. |
| provider | Provider name, for tools that dispatch on it. |
| provider\_details | OCI-specific values: compartment, VCN, subnet, network security group, load balancer, reserved IP, image, jumphost and NAT gateway OCIDs, fault domains and the build bucket. |
| rancher\_bootstrap\_password | Rancher initial admin password. null when rancher is not in components. |
| rancher\_hostname | Hostname Rancher's ingress is configured for. null when rancher is not in components. |
| rancher\_url | Rancher UI URL. null when rancher is not in components. |
| region | OCI region the cluster runs in. |
| security | SUSE Security (NeuVector): role, Manager URL and CA (management only) and federation endpoint. Null when neither security component is enabled. |
| security\_credentials | SUSE Security admin password and federation join token. Null when neither security component is enabled. |
<!-- END_TF_DOCS -->
