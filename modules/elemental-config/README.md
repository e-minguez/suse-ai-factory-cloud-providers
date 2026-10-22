# `modules/elemental-config`

Renders the Elemental, RKE2 and Helm configuration shared by every provider
module, the per-node Ignition, and the image `build_hash`. It creates no cloud
resources; it fetches the AI Factory release manifest at plan time (`http`
provider), generates the Rancher bootstrap password and the add-on secrets
(`random`) and the add-on certificates (`tls`).

## What it renders

- `elemental_files`: the Elemental config directory the build host runs
  `elemental customize` on. `release.yaml`, `install.yaml`, `butane.yaml`,
  `kubernetes/cluster.yaml`, `kubernetes/config/{server,agent}.yaml`, one Helm
  values file per enabled component, the Application Collection pull secret
  and Traefik manifests, extra files from the provider (`extra_config_files`),
  and `release_manifest.yaml`. Templates are in `templates/elemental/`.
  Comments are stripped from every file before hashing.
- `node_runtime_ignition`: per-node Ignition JSON delivered as `user_data`:
  hostname, role (`NODETYPE`, `IS_INIT_NODE`), the RKE2 `node-ip`, the Longhorn
  default-disk label (`suse_storage_nodes`) and, on servers, the canal
  `HelmChartConfig`. Roles live here, not in the image, so changing the node
  set never rebuilds it. The plan fails when a node exceeds `user_data_max_bytes`.
- `build_hash`: SHA-256 over the rendered files, the release manifest, the
  Elemental image, `core_platform_override`, the effective sysext overrides,
  `extra_build_inputs` and `image_rebuild` (when greater than 0). It is the only
  image rebuild trigger, so every build input a provider adds goes in
  `extra_build_inputs`.

## Config bundle

Providers whose `user_data` is plain text (vultr, exoscale, evroc) deliver
`elemental_files` as one compressed payload, `config_bundle`: the base64 gzip of
a self-extracting bash script (`config_bundle_script`) that takes the target
directory as `$1` and writes every file through a quoted heredoc, so contents
are never expanded. Compressing all files together keeps `user_data` small. A
file that does not end in a newline gains one (the only difference from
`elemental_files`); `.sh` files get mode 0755, the rest 0600. The output
rejects paths outside `[A-Za-z0-9._/-]` or containing `..`, and any file with a
line equal to the heredoc delimiter.

## Inputs a provider supplies

Platform differences enter as inputs, and the provider keeps the cloud
resources: `kernel_cmdline` (includes `ignition.platform.id`), `nodes`,
`api_vip`, `api_host` and `tls_san`, `vpc_cidr`, `canal_iface_regex` and
`pod_veth_mtu`, `user_data_max_bytes` and `compress_node_files`, and the
optional `extra_butane_units`, `extra_butane_files`, `extra_config_files` and
`enable_write_node_ip` (installs `write-node-ip.sh`, which pins the RKE2
node-ip on multi-NIC nodes). The remaining inputs mirror the common variables in
`modules/common/variables-common.tf`.

```hcl
module "elemental_config" {
  source = "../elemental-config"

  cluster_name        = var.cluster_name
  api_vip             = local.api_vip
  api_host            = local.api_host
  vpc_cidr            = local.vpc_cidr
  rke2_token          = random_password.token.result
  nodes               = local.nodes # hostname, type, init, node_ip, role, pool
  kernel_cmdline      = "console=ttyS0 ignition.platform.id=<platform>"
  user_data_max_bytes = 16384
  rancher_hostname    = local.rancher_hostname
  # ... accounts, components, aif_release and credentials from var.*
}
```

## Add-on components

`observability-server`, `observability-plugin`, `observability-agent`,
`security-management` and `security-downstream` (`addons.tf`) render
`kubernetes/manifests/<name>-priority.yaml` files, not `release.yaml` entries,
so they are part of `build_hash`. `observability-server` adds
`observability-agent` to `enabled_components`. Generated secrets and one
ECDSA CA per cluster, one ingress leaf certificate (SANs: every enabled ingress
host) and, for `security-management`, an RSA backend certificate come from
`random` and `tls`, and persist in state. `ingress_address` (the public IPv4 of
the ingress) builds the `obs-<ip>.sslip.io` and `neuvector-<ip>.sslip.io`
defaults and is required only when `observability_hostname` or
`security_hostname` is null and `ingress_domain` is null. With `ingress_domain`,
`obs.<domain>` and `neuvector.<domain>` are the defaults and a wildcard record
`*.<domain>` covers every derived name. With custom hostnames, DNS also needs records for
`fed-<security_hostname>`, `otlp-<observability_hostname>` and
`otlp-http-<observability_hostname>`. The ingress certificate is valid 820 days
and is re-issued within 30 days of expiry. The NeuVector chart version follows the Rancher
minor in the release manifest; an unknown minor fails the plan. New outputs:
`observability`, `observability_credentials` (sensitive), `security` and
`security_credentials` (sensitive), all null when their component is off.

## Release manifest and beta overrides

`aif_release` is a manifest URL or a version resolved to the SUSE/aif tag
`aif-operator-<version>`. With `core_platform_override` or an enabled
`sysext_image_overrides` entry, the manifest is rewritten in Terraform and
shipped to the build host as `release_manifest.yaml`, so the host builds from
exactly the manifest that was hashed. Both are beta workarounds, listed in
[docs/workarounds.md](../../docs/workarounds.md). Rationale for the rendering
choices is in [ADR 001](../../docs/decisions/001-elemental-config-rationale.md).

`terraform test` in this directory renders everything with fixtures and needs no
credentials.

## Inputs and outputs

Generated by `make docs`; do not edit between the markers.

<!-- BEGIN_TF_DOCS -->
## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| aif\_release | AI Factory release: a manifest URL (http:// or https://), or a version X.Y.Z[-pre] resolved to the SUSE/aif tag aif-operator-<version>. | `string` | `"2.3.0"` | no |
| api\_host | DNS name of the RKE2 API endpoint; added to the API server certificate SANs. | `string` | n/a | yes |
| api\_vip | Address of the RKE2 API endpoint (network.apiVIP in cluster.yaml). | `string` | n/a | yes |
| api\_vip\_mode | Elemental network.apiVIPMode: external skips MetalLB and expects a cloud load balancer. | `string` | `"external"` | no |
| appco\_password | Application Collection password or token, paired with appco\_username. | `string` | `null` | no |
| appco\_registry | Registry host used by the Application Collection image pull secret. | `string` | `"dp.apps.rancher.io"` | no |
| appco\_username | Application Collection username. Required with local-path-provisioner or suse-storage; recommended with aif-operator so it can pull its workloads right after deployment. | `string` | `null` | no |
| canal\_iface\_regex | Flannel --iface-regex written to the canal HelmChartConfig; null keeps the chart default. | `string` | `null` | no |
| cluster\_name | Cluster name; names the generated core platform manifest. | `string` | n/a | yes |
| components | AI Factory Helm charts and add-ons to enable. Rendered in canonical order, not the order given. | `list(string)` | <pre>[<br/>  "rancher",<br/>  "gpu-operator",<br/>  "local-path-provisioner",<br/>  "aif-operator"<br/>]</pre> | no |
| compress\_node\_files | Gzip the files embedded in per-node Ignition to save user\_data space. | `bool` | `false` | no |
| core\_platform\_override | Beta workaround: flatten the release manifest into a core platform manifest pinning these images. See docs/workarounds.md. | <pre>object({<br/>    os_image_base      = string<br/>    os_image_iso       = string<br/>    kubernetes_version = string<br/>    kubernetes_image   = string<br/>  })</pre> | `null` | no |
| elemental\_image | Container image that runs `elemental customize` on the build host. | `string` | `"registry.suse.com/beta/uc/elemental:3.1.0-6.5"` | no |
| enable\_write\_node\_ip | Add write-node-ip.sh and its unit to the image: on multi-NIC nodes it pins the RKE2 node-ip to the address inside vpc\_cidr. | `bool` | `false` | no |
| extra\_build\_inputs | Extra values hashed into build\_hash, for build inputs the provider module owns (for example the factory script). | `map(string)` | `{}` | no |
| extra\_butane\_files | Additional files baked into the image through butane.yaml. Mode is decimal. | <pre>list(object({<br/>    path     = string<br/>    mode     = optional(number, 493)<br/>    contents = string<br/>  }))</pre> | `[]` | no |
| extra\_butane\_units | Additional systemd units baked into the image through butane.yaml. | <pre>list(object({<br/>    name     = string<br/>    enabled  = optional(bool, true)<br/>    contents = optional(string)<br/>  }))</pre> | `[]` | no |
| extra\_config\_files | Additional files for the elemental config dir, keyed by relative path (for example network/configure-network.sh). | `map(string)` | `{}` | no |
| fips | Set cryptoPolicy: fips in install.yaml. Every node must be FIPS-ready. | `bool` | `false` | no |
| gpu\_driver\_repository | Registry path of the precompiled NVIDIA driver container. Experimental default; see docs/workarounds.md. | `string` | `"registry.opensuse.org/home/eminguez/branches/home/avicenzi/nvidia-for-bci-161/containerfile/third-party/nvidia"` | no |
| gpu\_driver\_version | NVIDIA driver branch of the precompiled driver container; must exist under gpu\_driver\_repository. | `string` | `"615"` | no |
| image\_disk\_size | Size of the raw image elemental builds (install.yaml raw.diskSize). | `string` | `"8G"` | no |
| image\_rebuild | Rebuild counter mixed into build\_hash when greater than 0; bumping it forces a new image. | `number` | `0` | no |
| ingress\_address | Public IPv4 the ingress (Traefik 80/443) answers on, for the sslip.io hostname defaults of the observability and security components. | `string` | `null` | no |
| ingress\_controller | RKE2 ingress-controller setting. Only traefik adds a HelmChartConfig. | `string` | `"traefik"` | no |
| ingress\_domain | Domain whose wildcard record points at the ingress; obs.<domain> and neuvector.<domain> become the default hostnames. Null keeps the sslip.io defaults. | `string` | `null` | no |
| kernel\_cmdline | Kernel command line of the built image, including ignition.platform.id and consoles. | `string` | n/a | yes |
| node\_user\_password\_hash | Crypt hash for node\_username. | `string` | n/a | yes |
| node\_username | Unprivileged login account created on every node. | `string` | `"suse"` | no |
| nodes | Cluster nodes. type is server or agent; role is control\_plane, worker or gpu (null: control\_plane for servers, gpu for agents); pool is the node pool, matched by suse\_storage\_nodes; init marks the node that bootstraps the cluster; node\_ip pins the RKE2 node-ip. | <pre>list(object({<br/>    hostname = string<br/>    type     = string<br/>    init     = optional(bool, false)<br/>    node_ip  = optional(string)<br/>    role     = optional(string)<br/>    pool     = optional(string)<br/>  }))</pre> | n/a | yes |
| nvidia\_api\_key | NVIDIA NGC API key. Optional, recommended with aif-operator; unset omits the nvidia credentials block. | `string` | `null` | no |
| nvidia\_username | NGC username paired with nvidia\_api\_key; NGC uses the literal $oauthtoken for API-key auth. | `string` | `"$oauthtoken"` | no |
| observability\_admin\_password | SUSE Observability admin password; a random one is generated when null. | `string` | `null` | no |
| observability\_allowed\_origins | Extra CORS origins for the SUSE Observability API, such as remote Rancher URLs. The local Rancher URL is added automatically. | `list(string)` | `[]` | no |
| observability\_bootstrap\_token | SUSE Observability service token used by the setup Jobs. Generated with observability-server when null; required for agent and plugin without a local server. | `string` | `null` | no |
| observability\_ca\_pem | PEM CA certificate of the remote SUSE Observability server. Required with observability\_server\_url. | `string` | `null` | no |
| observability\_hostname | Hostname of the SUSE Observability ingress; defaults to obs-<ingress\_address>.sslip.io when null. | `string` | `null` | no |
| observability\_license\_key | SUSE Observability license key. Required with observability-server. | `string` | `null` | no |
| observability\_opensearch\_credentials | OpenSearch credentials for the collector elasticsearch receiver; null disables the receiver. | <pre>object({<br/>    username = string<br/>    password = string<br/>  })</pre> | `null` | no |
| observability\_server\_url | https URL of a remote SUSE Observability server. Required for agent and plugin without observability-server, null otherwise. | `string` | `null` | no |
| observability\_sizing\_profile | SUSE Observability sizing profile: trial, 10-nonha, 20-nonha, 50-nonha, 100-nonha, 150-ha, 250-ha, 500-ha or 4000-ha. | `string` | `"trial"` | no |
| observability\_suse\_ai\_namespace | Namespace of the SUSE AI workloads the OpenTelemetry collector scrapes. | `string` | `"suse-private-ai"` | no |
| permit\_root\_ssh | Allow SSH logins as root and install ssh\_authorized\_keys for it. Debug toggle. | `bool` | `false` | no |
| pin\_single\_nic\_node\_ip | Make write-node-ip.sh pin single-NIC nodes too, waiting up to 10 minutes for an address inside vpc\_cidr; RKE2 does not start if none appears. For platforms whose DHCP can hand out an address outside the VPC range. | `bool` | `false` | no |
| pod\_veth\_mtu | Calico vethuMTU written to the canal HelmChartConfig; null keeps the chart default. | `number` | `null` | no |
| rancher\_bootstrap\_password | Rancher initial admin password; a random one is generated when null. | `string` | `null` | no |
| rancher\_hostname | Hostname of the Rancher ingress. | `string` | n/a | yes |
| rke2\_token | Shared RKE2 join token, generated by the provider module. | `string` | n/a | yes |
| root\_password\_hash | Crypt hash for the root account (for example from `openssl passwd -6`). | `string` | n/a | yes |
| security\_admin\_password | NeuVector admin password; a random one is generated when null. | `string` | `null` | no |
| security\_hostname | Hostname of the NeuVector Manager ingress; defaults to neuvector-<ingress\_address>.sslip.io when null. | `string` | `null` | no |
| security\_join\_token | NeuVector federation join token (a UUID). Required with security-downstream; generated with security-management when null. | `string` | `null` | no |
| security\_primary\_endpoint | host or host:port (default 443) of the primary NeuVector federation endpoint. Required with security-downstream. | `string` | `null` | no |
| security\_rancher\_url | Rancher URL (https://...) for NeuVector Rancher SSO; null uses the local Rancher when enabled, else SSO is off. | `string` | `null` | no |
| ssh\_authorized\_keys | SSH public keys for node\_username, and for root when permit\_root\_ssh is set. | `list(string)` | n/a | yes |
| suse\_registry\_password | SUSE registry password, paired with suse\_registry\_username. | `string` | `null` | no |
| suse\_registry\_username | SUSE registry username. Optional, set together with suse\_registry\_password; recommended with aif-operator. | `string` | `null` | no |
| suse\_storage\_nodes | Node roles (control\_plane, worker, gpu) or pool names whose nodes get the Longhorn default-disk label when suse-storage is enabled. A node matches by role or by pool. | `list(string)` | <pre>[<br/>  "control_plane"<br/>]</pre> | no |
| sysext\_image\_overrides | Beta workaround: per-extension OCI image overrides written into the release manifest, keyed by extension name. | `map(string)` | `{}` | no |
| tls\_san | Extra RKE2 tls-san entries written to server.yaml. | `list(string)` | `[]` | no |
| user\_data\_max\_bytes | Per-node user\_data size limit of the platform; the plan fails when a node's Ignition exceeds it. | `number` | n/a | yes |
| vpc\_cidr | Cluster network CIDR; used for the write-node-ip lookup and Traefik proxy-protocol trust. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| build\_hash | SHA-256 of every build input: rendered files, release manifest, elemental image, core platform override, sysext overrides and extra\_build\_inputs. Rebuild the image only when it changes. |
| build\_id | First 12 characters of build\_hash, for resource names and labels. |
| config\_bundle | base64gzip of config\_bundle\_script: all elemental\_files as one compressed payload for cloud-init write\_files (encoding gz+b64). Contains credentials. |
| config\_bundle\_script | Self-extracting bash script that writes every elemental\_files entry under the directory given as $1. Plain text; use config\_bundle for delivery. Contains credentials. |
| dockerconfigjson\_b64 | Base64 dockerconfigjson for the Application Collection pull secret; null without appco credentials. |
| effective\_sysext\_overrides | sysext\_image\_overrides narrowed to extensions that are enabled. |
| elemental\_file\_names | Relative paths in elemental\_files; not sensitive, usable as for\_each keys. |
| elemental\_files | Elemental config dir contents keyed by relative path, comments stripped, including release\_manifest.yaml. Contains credentials. |
| elemental\_files\_documented | elemental\_files with comments and without release\_manifest.yaml. Documentation aid only: nothing should consume it. |
| enabled\_components | Enabled components in canonical order. |
| enabled\_sysexts | systemd extensions required by the enabled components. |
| node\_runtime\_ignition | Per-node Ignition user data (JSON) keyed by hostname. Fails the plan when a node exceeds user\_data\_max\_bytes. |
| observability | SUSE Observability URL, CA certificate and OTLP endpoints; null unless observability-server is enabled. |
| observability\_credentials | SUSE Observability admin password and bootstrap token; null unless observability-server is enabled. |
| rancher\_bootstrap\_password | Rancher bootstrap password: the input when set, else a generated one. |
| release\_manifest | Release manifest for the build host, rewritten in Terraform when beta overrides apply. Same content as release\_manifest.yaml in elemental\_files. |
| release\_manifest\_url | URL the release manifest was fetched from. |
| security | SUSE Security (NeuVector) endpoints and CA; null unless security-management or security-downstream is enabled. url and ca\_pem are null on a downstream cluster. |
| security\_credentials | NeuVector admin password and federation join token; null unless a security component is enabled. |
| write\_node\_ip\_script | Rendered write-node-ip.sh, for providers that deliver it another way. |
<!-- END_TF_DOCS -->
