# Variables a user sets. Everything else keeps the module's default.
# Descriptions are pointers; modules/common/variables-common.tf and
# modules/evroc/variables.tf are the reference.

# --- Placement -----------------------------------------------------------

variable "region" {
  type        = string
  default     = null
  description = "evroc region. Null uses the provider's configured region."
}

variable "zones" {
  type        = list(string)
  default     = []
  description = "Zones the cluster spans. Empty uses a, b and c. Do not reorder on an existing cluster; subnets are numbered by position."
}

variable "project" {
  type        = string
  default     = null
  description = "evroc project. Null uses the provider's configured project."
}

variable "cluster_name" {
  type        = string
  default     = "suse-ai-factory"
  description = "Prefix of resource names and node hostnames."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Extra tags on every resource that supports them. Keys must not use the elemental- prefix or contain \"/\"."
}

# --- Access --------------------------------------------------------------

variable "admin_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to SSH to the jumphost and nodes and to read the build-status relay. Must include the address Terraform runs from."
}

variable "api_cidrs" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "CIDRs allowed to reach the public Kubernetes API listener on 6443."
}

variable "ingress_cidrs" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "CIDRs allowed to reach the ingress on 80/443."
}

variable "api_host" {
  type        = string
  default     = null
  description = "DNS name of the RKE2 API. Null uses rke2-<api_vip>.sslip.io."
}

variable "root_password_hash" {
  type        = string
  sensitive   = true
  description = "Crypt hash of the root password (openssl passwd -6)."
}

variable "ssh_authorized_keys" {
  type        = list(string)
  description = "SSH public keys for node_username and the jumphost."
}

variable "node_username" {
  type        = string
  default     = "suse"
  description = "Unprivileged login on every node (no sudo; use su -)."
}

variable "node_user_password_hash" {
  type        = string
  sensitive   = true
  description = "Crypt hash of the node_username password."
}

variable "permit_root_ssh" {
  type        = bool
  default     = false
  description = "Allow SSH logins as root on the nodes. Debug toggle."
}

# --- Sizing and nodes ----------------------------------------------------

variable "deploy_nodes" {
  type        = bool
  default     = true
  description = "false builds the image only and creates no nodes."
}

variable "control_plane_count" {
  type        = number
  default     = 3
  description = "Number of control-plane nodes: 1, or odd and at least 3."
}

variable "control_plane_instance_type" {
  type        = string
  default     = null
  description = "Compute profile of the control-plane nodes. Null uses c1a.m."
}

variable "control_plane_disk_size_gb" {
  type        = number
  default     = null
  description = "Boot disk size in GB of the control-plane nodes. Null uses 200."
}

variable "control_plane_public_ip" {
  type        = bool
  default     = false
  description = "Give control-plane nodes a public IP. Not needed for access or egress; each one uses public-IP quota."
}

variable "jumphost_instance_type" {
  type        = string
  default     = null
  description = "Compute profile of every build host. Null uses a1a.m."
}

variable "jumphost_disk_size_gb" {
  type        = number
  default     = null
  description = "Boot disk size in GB of every build host. Null uses 200."
}

variable "image_target_disk_gb" {
  type        = number
  default     = 32
  description = "Size in GB of the blank disk each build host writes the raw image onto."
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
  description = "GPU worker pools by name. evroc accepts kind vm, and placement spread or cluster; the zone must be a GPU zone (a)."
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

# --- AI Factory and credentials ------------------------------------------

variable "components" {
  type        = list(string)
  default     = ["rancher", "gpu-operator", "local-path-provisioner", "aif-operator"]
  description = "AI Factory Helm charts to enable. Changing this rebuilds the image."
}

variable "suse_storage_nodes" {
  type        = list(string)
  default     = ["control_plane"]
  description = "Where the suse-storage disks live: roles (control_plane, worker, gpu) and/or worker_pools / gpu_pools keys. At least three such nodes."
}

variable "aif_release" {
  type        = string
  default     = "2.3.0"
  description = "AI Factory version (X.Y.Z, resolved to tag aif-operator-<version>) or a manifest URL."
}

variable "rancher_hostname" {
  type        = string
  default     = null
  description = "Rancher ingress hostname. Null uses rancher-<api_vip>.sslip.io."
}

variable "rancher_bootstrap_password" {
  type        = string
  default     = null
  sensitive   = true
  description = "Rancher initial admin password. Null generates one."
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
  description = "Registry host the Application Collection pull secret authenticates against."
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
  description = "NGC username paired with nvidia_api_key."
}

variable "gpu_driver_repository" {
  type        = string
  default     = null
  description = "GPU driver container registry path. Null uses the module's experimental default."
}

variable "gpu_driver_version" {
  type        = string
  default     = null
  description = "GPU driver branch. Null uses the module's default."
}

# --- Deploy-script controlled --------------------------------------------

variable "image_ready" {
  type        = bool
  default     = false
  description = "Set by deploy.sh through pass2.auto.tfvars.json once the image builds are done."
}

variable "image_ids" {
  type        = map(string)
  default     = {}
  description = "Existing snapshots by zone to boot instead of building. Never the module's own image output."
}

variable "keep_build_artifacts" {
  type        = bool
  default     = false
  description = "Keep the image-target disks after the snapshots exist. Set by deploy.sh through pass2.auto.tfvars.json."
}

variable "image_rebuild" {
  type        = number
  default     = 0
  description = "Rebuild counter mixed into the image build hash. deploy.sh --rebuild bumps it in rebuild.auto.tfvars.json; do not set it by hand or in terraform.tfvars."
}
