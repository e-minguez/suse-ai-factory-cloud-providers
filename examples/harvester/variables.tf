# Only variables a user sets. Everything else keeps the module default; see
# modules/harvester/variables.tf and modules/common/variables-common.tf.

# --- Common ---------------------------------------------------------------

variable "cluster_name" {
  type        = string
  default     = "suse-ai-factory"
  description = "Prefix of resource names and node hostnames."
}

variable "region" {
  type        = string
  default     = "harvester"
  description = "Free-form region label; Harvester has no regions."
}

variable "zones" {
  type        = list(string)
  default     = []
  description = "Must be empty: Harvester has no zones."
}

variable "admin_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to SSH into the nodes and the build host. Accepted but not enforced: VLAN networks have no security groups."
}

variable "api_cidrs" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "CIDRs allowed to reach the Kubernetes API on 6443. Accepted but not enforced."
}

variable "ingress_cidrs" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "CIDRs allowed to reach the ingress on 80/443. Accepted but not enforced."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Extra tags on every resource that supports them. Keys must not use the elemental- prefix."
}

variable "deploy_nodes" {
  type        = bool
  default     = true
  description = "Create the nodes. false builds the image only."
}

variable "control_plane_count" {
  type        = number
  default     = 3
  description = "Number of control-plane nodes: 1, or odd and at least 3."
}

variable "control_plane_instance_type" {
  type        = string
  default     = null
  description = "Size of the control-plane VMs as \"<vcpu>x<memory_gib>\", for example \"8x32\". Null uses \"8x32\"."
}

variable "control_plane_public_ip" {
  type        = bool
  default     = false
  description = "Must be false: VMs attach to a VLAN network and have no public IP."
}

variable "jumphost_instance_type" {
  type        = string
  default     = null
  description = "Size of the buildhost VM, same syntax as control_plane_instance_type. Null uses \"4x8\"."
}

variable "jumphost_image" {
  type        = string
  default     = null
  description = "Existing buildhost image as <namespace>/<name>. Null downloads buildhost_image_url as an image."
}

variable "jumphost_username" {
  type        = string
  default     = "suse"
  description = "Login user of the buildhost. Empty makes the buildhost root-only."
}

variable "keep_build_artifacts" {
  type        = bool
  default     = false
  description = "Unused on harvester: the image target volume is removed with the buildhost."
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
  description = "GPU worker pools keyed by pool name; instance_type is \"<vcpu>x<memory_gib>\" and every key needs a gpu_devices entry. zone, public_ip and placement must stay unset."
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
  description = "Worker pools without GPUs, keyed by pool name. Same fields and provider limits as gpu_pools."
}

variable "image_id" {
  type        = string
  default     = null
  description = "Existing node image as <namespace>/<name> to boot instead of building one. Null builds the image."
}

variable "aif_release" {
  type        = string
  default     = "2.3.0"
  description = "AI Factory version (X.Y.Z) or a release manifest URL."
}

variable "components" {
  type        = list(string)
  default     = ["rancher", "gpu-operator", "local-path-provisioner", "aif-operator"]
  description = "AI Factory Helm charts to enable."
}

variable "suse_storage_nodes" {
  type        = list(string)
  default     = ["control_plane"]
  description = "Where the suse-storage disks live: roles (control_plane, worker, gpu) and/or worker_pools / gpu_pools keys. At least three such nodes."
}

variable "root_password_hash" {
  type        = string
  sensitive   = true
  description = "Crypt hash of the root password, for example from `openssl passwd -6`."
}

variable "node_username" {
  type        = string
  default     = "suse"
  description = "Unprivileged login account created on every node."
}

variable "node_user_password_hash" {
  type        = string
  sensitive   = true
  description = "Crypt hash of the node_username password."
}

variable "ssh_authorized_keys" {
  type        = list(string)
  description = "SSH public keys for node_username and the buildhost."
}

variable "permit_root_ssh" {
  type        = bool
  default     = false
  description = "Allow SSH logins as root. Debug toggle."
}

variable "appco_username" {
  type        = string
  default     = null
  sensitive   = true
  description = "Application Collection username. Required with local-path-provisioner or suse-storage; recommended with aif-operator so it can pull its workloads right after deployment."
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
  description = "Application Collection registry host."
}

variable "suse_registry_username" {
  type        = string
  default     = null
  sensitive   = true
  description = "SUSE registry username. Optional, set together with suse_registry_password; recommended with aif-operator."
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
  description = "NVIDIA NGC username paired with nvidia_api_key."
}

variable "rancher_hostname" {
  type        = string
  default     = null
  description = "Rancher hostname. Null derives rancher.<ingress_vip>.sslip.io."
}

variable "ingress_domain" {
  type        = string
  default     = null
  description = "A domain with a wildcard DNS record (`*.<domain>`) pointing at the ingress: a CNAME to the load balancer DNS name on aws, an A record to the ingress IP elsewhere. Hostnames become rancher.<domain>, obs.<domain> and neuvector.<domain>; null keeps the defaults."

  validation {
    condition     = var.ingress_domain == null || can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.ingress_domain))
    error_message = "ingress_domain must be a lowercase DNS name without scheme, leading \"*.\" or trailing dot."
  }
}

variable "rancher_bootstrap_password" {
  type        = string
  default     = null
  sensitive   = true
  description = "Rancher initial admin password. Null generates one."
}

variable "security_admin_password" {
  type        = string
  default     = null
  sensitive   = true
  description = "NeuVector admin password for the security-management and security-downstream components; a random one is generated when null."
}

variable "security_hostname" {
  type        = string
  default     = null
  description = "Hostname of the NeuVector Manager ingress (security-management). Null selects an sslip.io name from the ingress address."
}

variable "security_join_token" {
  type        = string
  default     = null
  sensitive   = true
  description = "NeuVector federation join token (a lowercase UUID). Required with security-downstream; generated when null with security-management."
}

variable "security_primary_endpoint" {
  type        = string
  default     = null
  description = "Federation endpoint of the primary NeuVector cluster as host or host:port (port defaults to 443). Required with security-downstream."
}

variable "security_rancher_url" {
  type        = string
  default     = null
  description = "Rancher URL (https://...) used for NeuVector Rancher SSO. Null uses the local Rancher when rancher is enabled, otherwise SSO is off."
}

variable "observability_license_key" {
  type        = string
  default     = null
  sensitive   = true
  description = "SUSE Observability license key. Required with observability-server."
}

variable "observability_admin_password" {
  type        = string
  default     = null
  sensitive   = true
  description = "SUSE Observability admin password; a random one is generated when null."
}

variable "observability_sizing_profile" {
  type        = string
  default     = "trial"
  description = "SUSE Observability sizing profile (trial, 10-nonha, 20-nonha, 50-nonha, 100-nonha, 150-ha, 250-ha, 500-ha or 4000-ha). Used with observability-server."
}

variable "observability_hostname" {
  type        = string
  default     = null
  description = "Hostname of the SUSE Observability ingress (observability-server). Null selects an sslip.io name from the ingress address."
}

variable "observability_bootstrap_token" {
  type        = string
  default     = null
  sensitive   = true
  description = "SUSE Observability service token used by agents and the Rancher plugin. Generated when null with observability-server; required for observability-agent and observability-plugin without a local server."
}

variable "observability_server_url" {
  type        = string
  default     = null
  description = "HTTPS URL of a remote SUSE Observability server. Required for observability-agent and observability-plugin without observability-server; must be null with it."
}

variable "observability_ca_pem" {
  type        = string
  default     = null
  description = "PEM CA certificate of the remote SUSE Observability server (the observability output ca_pem). Required with observability_server_url."
}

variable "observability_allowed_origins" {
  type        = list(string)
  default     = []
  description = "Extra CORS origins allowed by the SUSE Observability server, for example remote Rancher URLs. The local Rancher URL is added automatically."
}

variable "observability_suse_ai_namespace" {
  type        = string
  default     = "suse-private-ai"
  description = "Namespace of the SUSE AI workloads whose metrics the observability-agent collector scrapes."
}

variable "observability_opensearch_credentials" {
  type = object({
    username = string
    password = string
  })
  default     = null
  sensitive   = true
  description = "OpenSearch username and password for the collector elasticsearch receiver. Null disables the receiver."
}

# --- Harvester ------------------------------------------------------------

variable "harvester_kubeconfig_path" {
  type        = string
  default     = null
  description = "Path of the Harvester cluster's kubeconfig; null uses the KUBECONFIG environment variable, then ~/.kube/config. A path keeps its content out of state."
}

variable "harvester_kubecontext" {
  type        = string
  default     = null
  description = "Kubeconfig context to use. Null uses the current one."
}

variable "harvester_namespace" {
  type        = string
  description = "Existing namespace that holds every object of the cluster."
}

variable "vpc_id" {
  type        = string
  description = "Existing Harvester VM network as <namespace>/<name>, for example \"harvester-public/vlan-2006\". It needs DHCP and egress."
}

variable "api_vip" {
  type        = string
  description = "Static IPv4 of the Kubernetes API, inside vpc_cidr and outside the DHCP range."
}

variable "ingress_vip" {
  type        = string
  description = "Static IPv4 of the ingress controller, inside vpc_cidr and outside the DHCP range; different from api_vip."
}

variable "storage_class_name" {
  type        = string
  default     = null
  description = "StorageClass for the image target volume and the images. Null uses the cluster default."
}

variable "disk_cache_mode" {
  type        = string
  default     = null
  description = "KubeVirt cache mode of the node root disks: none, writethrough or writeback; null keeps the Harvester default. writeback speeds up writes but keeps guest flushes, so etcd fsync latency barely changes."

  validation {
    condition     = var.disk_cache_mode == null || contains(["none", "writethrough", "writeback"], coalesce(var.disk_cache_mode, "-"))
    error_message = "disk_cache_mode must be none, writethrough or writeback (KubeVirt has no unsafe mode; see etcd_unsafe_no_fsync)."
  }
}

variable "node_storage_classes" {
  type        = map(string)
  default     = {}
  description = "StorageClass per node group, keyed by \"cp\" (control planes), a gpu_pools or worker_pools key, or \"buildhost\"; the rest use storage_class_name. Every extra class gets its own export of the node image (no clone without encryption)."
}

variable "buildhost_power_off" {
  type        = bool
  default     = true
  description = "Power the buildhost off once the image is written and Terraform has read the done status. It only builds: nodes are reached directly on the VM network."
}

variable "buildhost_image_url" {
  type        = string
  default     = "https://download.opensuse.org/distribution/leap/16.0/appliances/Leap-16.0-Minimal-VM.x86_64-Cloud.qcow2"
  description = "Image Harvester downloads for the buildhost when jumphost_image is null."
}

variable "gpu_devices" {
  type = map(object({
    device_name = string
    count       = optional(number, 1)
  }))
  default     = {}
  description = "Host devices per node, keyed by gpu_pools key or \"cp\" (every control plane): the KubeVirt resource name, for example \"nvidia.com/GA102GL_A10\", and the count per node."
}

variable "image_rebuild" {
  type        = number
  default     = 0
  description = "Rebuild counter mixed into the image build hash. deploy.sh --rebuild bumps it in rebuild.auto.tfvars.json; do not set it by hand or in terraform.tfvars."
}

variable "vpc_cidr" {
  type        = string
  default     = null
  description = "IPv4 subnet of the VM network in vpc_id. Required: both VIPs and the node addresses must lie inside it."
}

variable "control_plane_disk_size_gb" {
  type        = number
  default     = null
  description = "Root disk size in GB of the control-plane VMs. Null uses 100."
}

variable "jumphost_disk_size_gb" {
  type        = number
  default     = null
  description = "Root disk size in GB of the buildhost. Null uses 60."
}

variable "etcd_unsafe_no_fsync" {
  type        = bool
  default     = false
  description = "DANGEROUS: disables fsync in etcd (etcd --unsafe-no-fsync), so a host crash or power loss can corrupt etcd and lose the cluster. Only for throwaway clusters on disks too slow for etcd."
}
