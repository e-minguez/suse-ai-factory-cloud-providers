# Only variables a user sets. Everything else keeps the module default; see
# modules/vultr/variables.tf and modules/common/variables-common.tf.

# --- Common ---------------------------------------------------------------

variable "cluster_name" {
  type        = string
  default     = "suse-ai-factory"
  description = "Prefix of resource names and node hostnames."
}

variable "region" {
  type        = string
  description = "Vultr region ID to deploy into, for example \"ams\"."
}

variable "admin_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to reach the jumphost over SSH."
}

variable "api_cidrs" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "CIDRs allowed to reach the public Kubernetes API listener on 6443."
}

variable "ingress_cidrs" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "CIDRs allowed to reach the ingress load balancer on 80/443."
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
  description = "Vultr plan ID of the control-plane nodes. Null uses the module default."
}

variable "jumphost_instance_type" {
  type        = string
  default     = null
  description = "Vultr plan ID of the jumphost. Null uses the module default."
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
  description = "GPU worker pools keyed by pool name. kind = \"bare_metal\" takes a vbm-* plan; zone, disk_size_gb and placement must stay null on this provider."
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
  description = "Existing snapshot ID to boot instead of building one. Null builds the image."
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
  description = "SSH public keys for node_username and the jumphost."
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
  description = "Rancher hostname. Null derives rancher-<ingress IP>.sslip.io."
}

variable "rancher_bootstrap_password" {
  type        = string
  default     = null
  sensitive   = true
  description = "Rancher initial admin password. Null generates one."
}

# --- Vultr ----------------------------------------------------------------

variable "vultr_api_key" {
  type        = string
  sensitive   = true
  description = "Vultr API key, used by the vultr provider, the plan-time checks and the wait scripts."
}

variable "ssh_key_ids" {
  type        = list(string)
  default     = []
  description = "Vultr SSH key IDs injected into the jumphost."
}

variable "mdisk_mode" {
  type        = string
  default     = "none"
  description = "Managed disk mode of bare metal worker and GPU nodes: raid1, jbod or none."
}

# Filled by deploy.sh on pass 2 through pass2.auto.tfvars.json.
variable "lb_backend_instance_ids" {
  type        = list(string)
  default     = []
  description = "Instance IDs attached to the load balancers; set by deploy.sh on pass 2."
}

variable "lb_supervisor_extra_cidrs" {
  type        = list(string)
  default     = []
  description = "Extra CIDRs allowed on the load balancer port 9345; set by deploy.sh on pass 2."
}

variable "agent_cloud_extra_cidrs" {
  type        = list(string)
  default     = []
  description = "Extra CIDRs allowed on the cloud agent node firewall group; set by deploy.sh on pass 2."
}

variable "image_import_port_open" {
  type        = bool
  default     = true
  description = "Allow tcp/80 on the jumphost for the snapshot import; set by deploy.sh."
}

variable "image_rebuild" {
  type        = number
  default     = 0
  description = "Rebuild counter mixed into the image build hash. deploy.sh --rebuild bumps it in rebuild.auto.tfvars.json; do not set it by hand or in terraform.tfvars."
}
