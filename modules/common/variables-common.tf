# Variables common to every provider module. Symlinked as
# modules/<p>/variables-common.tf; edit this file, never the link.
# Provider-specific limits on these variables are check/precondition blocks
# in the provider module. A null default means "use the provider default".

# --- Placement and network -----------------------------------------------

variable "cluster_name" {
  type        = string
  default     = "suse-ai-factory"
  description = "Prefix of resource names and node hostnames (<cluster_name>-cp-NN, <cluster_name>-<pool>-NN)."

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.cluster_name))
    error_message = "cluster_name must be a valid DNS label: lowercase alphanumerics and hyphens, not starting or ending with a hyphen."
  }
}

variable "region" {
  type        = string
  default     = null
  description = "Provider region or location. Required by providers that have no region default; the provider module checks it."
}

variable "zones" {
  type        = list(string)
  default     = []
  description = "Zone suffixes the cluster spans (for example [\"a\", \"b\", \"c\"]); control planes are spread round-robin. Empty uses the provider default; providers without zones accept at most one entry."

  validation {
    condition     = length(distinct(var.zones)) == length(var.zones)
    error_message = "zones must not repeat a zone."
  }

  validation {
    condition     = alltrue([for z in var.zones : can(regex("^[a-z0-9]([a-z0-9-]{0,14}[a-z0-9])?$", z))])
    error_message = "Every zone must be 1-16 characters of lowercase alphanumerics and hyphens, not starting or ending with a hyphen."
  }
}

variable "vpc_cidr" {
  type        = string
  default     = null
  description = "IPv4 CIDR of the cluster network, from which subnets are derived; null uses the provider default. Must not overlap the RKE2 cluster (10.42.0.0/16) or service (10.43.0.0/16) CIDRs."

  validation {
    condition     = var.vpc_cidr == null || can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block, for example \"10.20.0.0/16\"."
  }

  validation {
    condition = var.vpc_cidr == null || !can(cidrhost(var.vpc_cidr, 0)) || !anytrue([
      for c in ["10.42.0.0/16", "10.43.0.0/16"] :
      cidrhost(format("%s/%d", cidrhost(var.vpc_cidr, 0), min(tonumber(split("/", var.vpc_cidr)[1]), 16)), 0) == cidrhost(format("%s/%d", cidrhost(c, 0), min(tonumber(split("/", var.vpc_cidr)[1]), 16)), 0)
    ])
    error_message = "vpc_cidr must not overlap the RKE2 default cluster-cidr 10.42.0.0/16 or service-cidr 10.43.0.0/16."
  }
}

variable "vpc_mtu" {
  type        = number
  default     = null
  description = "MTU of the cluster network interfaces; the pod MTU is derived from it. Null uses the provider default."

  validation {
    condition     = var.vpc_mtu == null || (var.vpc_mtu >= 1280 && var.vpc_mtu <= 9216)
    error_message = "vpc_mtu must be between 1280 and 9216."
  }
}

variable "admin_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to reach the jumphost and nodes over SSH. No default: an empty list locks everyone out."

  validation {
    condition     = length(var.admin_cidrs) > 0
    error_message = "admin_cidrs must contain at least one CIDR block."
  }

  validation {
    condition     = alltrue([for c in var.admin_cidrs : can(cidrhost(c, 0))])
    error_message = "Every admin_cidrs entry must be a CIDR block with an explicit prefix, for example \"203.0.113.1/32\"."
  }
}

variable "ingress_cidrs" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "CIDRs allowed to reach the ingress on 80/443, which serves the Rancher UI. Narrow it for clusters that are not public."

  validation {
    condition     = alltrue([for c in var.ingress_cidrs : can(cidrhost(c, 0))])
    error_message = "Every ingress_cidrs entry must be a CIDR block with an explicit prefix, for example \"203.0.113.1/32\"."
  }
}

variable "api_cidrs" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "CIDRs allowed to reach the public Kubernetes API listener on 6443. Narrow it to keep kubectl access off the internet."

  validation {
    condition     = length(var.api_cidrs) > 0
    error_message = "api_cidrs must contain at least one CIDR block."
  }

  validation {
    condition     = alltrue([for c in var.api_cidrs : can(cidrhost(c, 0))])
    error_message = "Every api_cidrs entry must be a CIDR block with an explicit prefix, for example \"203.0.113.1/32\"."
  }
}

variable "api_host" {
  type        = string
  default     = null
  description = "DNS name of the RKE2 API, added to the API server certificate SANs. Null derives a provider default."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Extra tags or labels on every resource that supports them. Keys must not use the elemental- prefix, which the module manages."

  validation {
    condition     = alltrue([for k in keys(var.tags) : !startswith(k, "elemental-")])
    error_message = "tags keys must not start with elemental-: the module manages those labels."
  }
}

# --- Compute -------------------------------------------------------------

variable "deploy_nodes" {
  type        = bool
  default     = true
  description = "Provision control-plane, worker and GPU nodes. false builds the image only and creates no nodes."
}

variable "control_plane_count" {
  type        = number
  default     = 3
  description = "Number of control-plane nodes: 1 (single node, no etcd quorum) or odd and at least 3. Growing from 1 only adds nodes."

  validation {
    condition     = var.control_plane_count == 1 || (var.control_plane_count >= 3 && var.control_plane_count % 2 == 1)
    error_message = "control_plane_count must be 1 or odd and at least 3."
  }
}

variable "control_plane_instance_type" {
  type        = string
  default     = null
  description = "Machine type, flavor or plan of the control-plane nodes. Null uses the provider default (about 4 vCPU / 16 GiB)."
}

variable "control_plane_disk_size_gb" {
  type        = number
  default     = null
  description = "Root disk size in GB of the control-plane nodes. Null uses the provider default; providers whose plans fix the disk reject a value."

  validation {
    condition     = var.control_plane_disk_size_gb == null || var.control_plane_disk_size_gb > 0
    error_message = "control_plane_disk_size_gb must be positive."
  }
}

variable "control_plane_public_ip" {
  type        = bool
  default     = false
  description = "Give control-plane nodes a public IP. Not needed for access or egress on providers with NAT; providers that never assign one reject true."
}

variable "gpu_pools" {
  type = map(object({
    instance_type = string
    count         = optional(number, 1)
    disk_size_gb  = optional(number)
    zone          = optional(string)
    public_ip     = optional(bool, false)
    kind          = optional(string, "vm")
    placement     = optional(string)
  }))
  default     = {}
  description = "GPU worker pools keyed by pool name. instance_type is the provider's type, flavor or plan; kind is vm or bare_metal; fields a provider does not support must be null."

  validation {
    condition     = alltrue([for k in keys(var.gpu_pools) : can(regex("^[a-z0-9]([a-z0-9-]{0,14}[a-z0-9])?$", k))])
    error_message = "Every gpu_pools key must be 1-16 characters of lowercase alphanumerics and hyphens, not starting or ending with a hyphen, because it becomes part of a hostname."
  }

  validation {
    condition     = !contains(keys(var.gpu_pools), "cp")
    error_message = "\"cp\" is reserved for control-plane hostnames and cannot be a gpu_pools key."
  }

  validation {
    condition     = !contains(keys(var.gpu_pools), "worker")
    error_message = "\"worker\" cannot be a gpu_pools key: in suse_storage_nodes it selects every worker_pools node."
  }

  validation {
    condition     = alltrue([for k, p in var.gpu_pools : p.count >= 0])
    error_message = "Every gpu_pools count must be >= 0."
  }

  validation {
    condition     = alltrue([for k, p in var.gpu_pools : p.disk_size_gb == null || coalesce(p.disk_size_gb, 1) > 0])
    error_message = "Every gpu_pools disk_size_gb must be positive when set."
  }

  validation {
    condition     = alltrue([for k, p in var.gpu_pools : contains(["vm", "bare_metal"], p.kind)])
    error_message = "Every gpu_pools kind must be \"vm\" or \"bare_metal\"."
  }

  validation {
    condition     = alltrue([for k, p in var.gpu_pools : p.zone == null || length(var.zones) == 0 || contains(var.zones, coalesce(p.zone, "-"))])
    error_message = "Every gpu_pools zone must be one of var.zones."
  }

  validation {
    condition     = alltrue([for k in keys(var.gpu_pools) : length("${var.cluster_name}-${k}-00") <= 63])
    error_message = "cluster_name plus a pool key must leave the hostname \"<cluster_name>-<pool>-NN\" within 63 characters."
  }
}

variable "worker_pools" {
  type = map(object({
    instance_type = string
    count         = optional(number, 1)
    disk_size_gb  = optional(number)
    zone          = optional(string)
    public_ip     = optional(bool, false)
    kind          = optional(string, "vm")
    placement     = optional(string)
  }))
  default     = {}
  description = "Worker pools without GPUs keyed by pool name, with the same fields as gpu_pools. Hostnames are <cluster_name>-<pool>-NN, so keys must not collide with gpu_pools keys."

  validation {
    condition     = alltrue([for k in keys(var.worker_pools) : can(regex("^[a-z0-9]([a-z0-9-]{0,14}[a-z0-9])?$", k))])
    error_message = "Every worker_pools key must be 1-16 characters of lowercase alphanumerics and hyphens, not starting or ending with a hyphen, because it becomes part of a hostname."
  }

  validation {
    condition     = !contains(keys(var.worker_pools), "cp")
    error_message = "\"cp\" is reserved for control-plane hostnames and cannot be a worker_pools key."
  }

  validation {
    condition     = !contains(keys(var.worker_pools), "gpu")
    error_message = "\"gpu\" cannot be a worker_pools key: in suse_storage_nodes it selects every gpu_pools node."
  }

  validation {
    condition     = alltrue([for k, p in var.worker_pools : p.count >= 0])
    error_message = "Every worker_pools count must be >= 0."
  }

  validation {
    condition     = alltrue([for k, p in var.worker_pools : p.disk_size_gb == null || coalesce(p.disk_size_gb, 1) > 0])
    error_message = "Every worker_pools disk_size_gb must be positive when set."
  }

  validation {
    condition     = alltrue([for k, p in var.worker_pools : contains(["vm", "bare_metal"], p.kind)])
    error_message = "Every worker_pools kind must be \"vm\" or \"bare_metal\"."
  }

  validation {
    condition     = alltrue([for k, p in var.worker_pools : p.zone == null || length(var.zones) == 0 || contains(var.zones, coalesce(p.zone, "-"))])
    error_message = "Every worker_pools zone must be one of var.zones."
  }

  validation {
    condition     = alltrue([for k in keys(var.worker_pools) : length("${var.cluster_name}-${k}-00") <= 63])
    error_message = "cluster_name plus a pool key must leave the hostname \"<cluster_name>-<pool>-NN\" within 63 characters."
  }

  validation {
    condition     = length(setintersection(keys(var.worker_pools), keys(var.gpu_pools))) == 0
    error_message = "worker_pools and gpu_pools keys must differ: both become \"<cluster_name>-<pool>-NN\" hostnames."
  }
}

# --- Build host and image ------------------------------------------------

variable "jumphost_instance_type" {
  type        = string
  default     = null
  description = "Machine type, flavor or plan of the jumphost that builds the image and serves as SSH bastion. Null uses the provider default."
}

variable "jumphost_disk_size_gb" {
  type        = number
  default     = null
  description = "Root disk size in GB of the jumphost. Null uses the provider default; providers whose plans fix the disk reject a value."

  validation {
    condition     = var.jumphost_disk_size_gb == null || var.jumphost_disk_size_gb > 0
    error_message = "jumphost_disk_size_gb must be positive."
  }
}

variable "jumphost_image" {
  type        = string
  default     = null
  description = "OS image (AMI, image name or OS ID) of the jumphost. Null uses the provider default (an openSUSE Leap image)."
}

variable "jumphost_username" {
  type        = string
  default     = "suse"
  description = "Login user of the jumphost. Empty makes the jumphost root-only."
}

variable "image_id" {
  type        = string
  default     = null
  description = "Existing image (AMI or snapshot) to boot instead of building one. Null builds the image. Providers with per-zone images use image_ids."
}

# tflint-ignore: terraform_unused_declarations # vultr has no separate build resources
variable "keep_build_artifacts" {
  type        = bool
  default     = false
  description = "Keep the intermediate build artifacts (raw image, build disks) after the image is registered. No effect on vultr, which builds on the jumphost."
}

variable "elemental_image" {
  type        = string
  default     = "registry.suse.com/beta/uc/elemental:3.1.0-6.5"
  description = "Container image that runs `elemental customize` on the build host."
}

variable "image_disk_size" {
  type        = string
  default     = "8G"
  description = "Size of the raw image elemental builds (install.yaml raw.diskSize)."

  validation {
    condition     = can(regex("^[1-9][0-9]*[KMGT]$", var.image_disk_size))
    error_message = "image_disk_size must match <positive integer><K|M|G|T>, e.g. \"35G\"."
  }
}

variable "fips" {
  type        = bool
  default     = false
  description = "Set cryptoPolicy: fips in install.yaml. Every node must be FIPS-ready."
}

variable "aif_release" {
  type        = string
  default     = "2.3.0"
  description = "AI Factory release: a manifest URL (http:// or https://), or a version X.Y.Z[-pre] resolved to the SUSE/aif tag aif-operator-<version>."

  validation {
    condition     = can(regex("^https?://", var.aif_release)) || can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.]+)?$", var.aif_release))
    error_message = "aif_release must be a manifest URL (http:// or https://) or a full X.Y.Z version with an optional pre-release suffix, for example \"2.3.0\" or \"2.3.0-dev.2\"."
  }

  validation {
    condition = can(regex("^https?://", var.aif_release)) || !can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.]+)?$", var.aif_release)) || (
      tonumber(split(".", split("-", var.aif_release)[0])[0]) > 2 ||
      tonumber(split(".", split("-", var.aif_release)[0])[1]) >= 1
    )
    error_message = "aif_release versions must be 2.1.0 or newer: earlier tags have no uc-release-manifest/release_manifest.yaml."
  }
}

variable "core_platform_override" {
  type = object({
    os_image_base      = string
    os_image_iso       = string
    kubernetes_version = string
    kubernetes_image   = string
  })
  default = {
    os_image_base      = "registry.suse.com/beta/uc/base-os-kernel-default:16.1-73.2"
    os_image_iso       = "registry.suse.com/beta/uc/base-os-kernel-default-iso:16.1-73.3"
    kubernetes_version = "v1.35.6+rke2r1"
    kubernetes_image   = "registry.suse.com/elemental/rke2/rke2-tar:1.35.6_rke2r1-9.1"
  }
  description = "Beta workaround: flatten the release manifest into a core platform manifest pinning these images; null disables it. See docs/workarounds.md."

  validation {
    condition = var.core_platform_override == null || !can(regex(
      "registry\\.suse\\.com/elemental/base-os-kernel-default", var.core_platform_override.os_image_iso
    ))
    error_message = "core_platform_override.os_image_iso points at the GA elemental/ repo, whose elemental3ctl ignores initrdExtensions. Use a beta/uc/ image."
  }
}

variable "sysext_image_overrides" {
  type        = map(string)
  default     = { suse-storage = "registry.suse.com/beta/uc/longhorn:5.279-4.13" }
  description = "Beta workaround: per-extension OCI image overrides written into the release manifest, keyed by extension name. See docs/workarounds.md."

  validation {
    condition     = alltrue([for name in keys(var.sysext_image_overrides) : can(regex("^[a-z0-9][a-z0-9._-]*$", name))])
    error_message = "sysext_image_overrides keys must be extension names as the release manifest spells them, for example \"suse-storage\"."
  }

  validation {
    condition     = alltrue([for image in values(var.sysext_image_overrides) : length(image) > 0 && !can(regex("[[:space:]'\"]", image))])
    error_message = "sysext_image_overrides values must be non-empty OCI image references without whitespace or quotes."
  }
}

variable "components" {
  type        = list(string)
  default     = ["rancher", "gpu-operator", "local-path-provisioner", "aif-operator"]
  description = "AI Factory Helm charts to enable. Rendered in canonical order, not the order given."

  validation {
    condition = alltrue([
      for c in var.components : contains(
        ["cert-manager", "rancher", "gpu-operator", "local-path-provisioner", "suse-storage", "aif-operator"], c
      )
    ])
    error_message = "components entries must be one of: cert-manager, rancher, gpu-operator, local-path-provisioner, suse-storage, aif-operator."
  }

  validation {
    condition     = length(var.components) == length(distinct(var.components))
    error_message = "components must not contain duplicate entries."
  }

  validation {
    condition     = !(contains(var.components, "local-path-provisioner") && contains(var.components, "suse-storage"))
    error_message = "components cannot list both local-path-provisioner and suse-storage: both set the default StorageClass."
  }

  validation {
    condition     = !contains(var.components, "aif-operator") || contains(var.components, "rancher")
    error_message = "components lists aif-operator without rancher, which the AIF release manifest declares as its dependency."
  }
}

variable "suse_storage_nodes" {
  type        = list(string)
  default     = ["control_plane"]
  description = "Where the suse-storage (Longhorn) disks live: roles (control_plane, worker for all worker_pools, gpu for all gpu_pools) and/or pool names, e.g. [\"control_plane\", \"storage\"]. At least three such nodes are required."

  validation {
    condition     = length(var.suse_storage_nodes) > 0 && alltrue([for r in var.suse_storage_nodes : contains(concat(["control_plane", "worker", "gpu"], keys(var.worker_pools), keys(var.gpu_pools)), r)])
    error_message = "suse_storage_nodes must be a non-empty list of roles (control_plane, worker, gpu) or keys of worker_pools / gpu_pools."
  }

  validation {
    condition = !contains(var.components, "suse-storage") || (
      (contains(var.suse_storage_nodes, "control_plane") ? var.control_plane_count : 0)
      + sum(concat([0], [for k, p in var.worker_pools : p.count if contains(var.suse_storage_nodes, "worker") || contains(var.suse_storage_nodes, k)]))
      + sum(concat([0], [for k, p in var.gpu_pools : p.count if contains(var.suse_storage_nodes, "gpu") || contains(var.suse_storage_nodes, k)]))
    ) >= 3
    error_message = "suse-storage needs at least three nodes holding its disks (suse_storage_nodes = ${jsonencode(var.suse_storage_nodes)}). Add nodes, change suse_storage_nodes, or use local-path-provisioner."
  }
}

variable "ingress_controller" {
  type        = string
  default     = "traefik"
  description = "RKE2 ingress-controller setting. Only traefik adds a HelmChartConfig."

  validation {
    condition     = contains(["none", "traefik", "ingress-nginx"], var.ingress_controller)
    error_message = "ingress_controller must be one of: none, traefik, ingress-nginx."
  }
}

variable "root_password_hash" {
  type        = string
  sensitive   = true
  description = "Crypt hash for the root account (for example from `openssl passwd -6`)."
}

variable "node_username" {
  type        = string
  default     = "suse"
  description = "Unprivileged login account created on every node."
}

variable "node_user_password_hash" {
  type        = string
  sensitive   = true
  description = "Crypt hash for node_username."
}

variable "ssh_authorized_keys" {
  type        = list(string)
  description = "SSH public keys for node_username, and for root when permit_root_ssh is set."
}

variable "permit_root_ssh" {
  type        = bool
  default     = false
  description = "Allow SSH logins as root and install ssh_authorized_keys for it. Debug toggle."
}

variable "appco_username" {
  type        = string
  default     = null
  sensitive   = true
  description = "Application Collection username. Required with local-path-provisioner or suse-storage; recommended with aif-operator so it can pull its workloads right after deployment."

  validation {
    condition = (
      !(contains(var.components, "local-path-provisioner") || contains(var.components, "suse-storage"))
      || try(trimspace(var.appco_username) != "" && trimspace(var.appco_password) != "", false)
    )
    error_message = "local-path-provisioner and suse-storage are pulled from Application Collection and need appco_username and appco_password."
  }

  validation {
    condition     = try(trimspace(var.appco_username) != "", false) == try(trimspace(var.appco_password) != "", false)
    error_message = "appco_username and appco_password must be set together."
  }
}

variable "appco_password" {
  type        = string
  default     = null
  sensitive   = true
  description = "Application Collection password or token, paired with appco_username."
}

variable "appco_registry" {
  type        = string
  default     = "dp.apps.rancher.io"
  description = "Registry host used by the Application Collection image pull secret."
}

variable "suse_registry_username" {
  type        = string
  default     = null
  sensitive   = true
  description = "SUSE registry username. Optional, set together with suse_registry_password; recommended with aif-operator."

  validation {
    condition     = try(trimspace(var.suse_registry_username) != "", false) == try(trimspace(var.suse_registry_password) != "", false)
    error_message = "suse_registry_username and suse_registry_password must be set together."
  }
}

variable "suse_registry_password" {
  type        = string
  default     = null
  sensitive   = true
  description = "SUSE registry password, paired with suse_registry_username."
}

variable "nvidia_api_key" {
  type        = string
  default     = null
  sensitive   = true
  description = "NVIDIA NGC API key. Optional, recommended with aif-operator; unset omits the nvidia credentials block."
}

variable "nvidia_username" {
  type        = string
  default     = "$oauthtoken"
  description = "NGC username paired with nvidia_api_key; NGC uses the literal $oauthtoken for API-key auth."

  validation {
    condition     = trimspace(var.nvidia_username) != ""
    error_message = "nvidia_username must not be empty."
  }
}

variable "gpu_driver_repository" {
  type        = string
  default     = "registry.opensuse.org/home/eminguez/branches/home/avicenzi/nvidia-for-bci-161/containerfile/third-party/nvidia"
  description = "Registry path of the precompiled NVIDIA driver container. Experimental default; see docs/workarounds.md."
  nullable    = false
}

variable "gpu_driver_version" {
  type        = string
  default     = "615"
  description = "NVIDIA driver branch of the precompiled driver container; must exist under gpu_driver_repository."
  nullable    = false
}

variable "rancher_hostname" {
  type        = string
  default     = null
  description = "Hostname of the Rancher ingress. Null selects a provider-specific default."
}

variable "rancher_bootstrap_password" {
  type        = string
  default     = null
  sensitive   = true
  description = "Rancher initial admin password; a random one is generated when null."
}

variable "image_rebuild" {
  type        = number
  default     = 0
  description = "Rebuild counter mixed into the image build hash. deploy.sh --rebuild bumps it in rebuild.auto.tfvars.json; do not set it by hand unless you know why."
  nullable    = false

  validation {
    condition     = var.image_rebuild >= 0 && var.image_rebuild == floor(var.image_rebuild)
    error_message = "image_rebuild must be a whole number >= 0."
  }
}
