# Variables a user sets. Everything else keeps the module default; names, types
# and defaults match modules/common/variables-common.tf, which holds the
# validations and full descriptions.

variable "region" {
  type        = string
  description = "AWS region to deploy into, for example \"us-east-1\". Required."
}

variable "zones" {
  type        = list(string)
  default     = []
  description = "Availability zone suffixes to span, for example [\"a\", \"b\", \"c\"]. Empty uses the first three zones of the region."
}

variable "cluster_name" {
  type        = string
  default     = "suse-ai-factory"
  description = "Prefix of resource names and node hostnames. At most 21 characters on aws."
}

variable "admin_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to reach the build host over SSH."
}

variable "api_cidrs" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "CIDRs allowed to reach the public Kubernetes API listener on 6443."
}

variable "ingress_cidrs" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "CIDRs allowed to reach the ingress on 80/443, which serves the Rancher UI."
}

variable "api_host" {
  type        = string
  default     = null
  description = "DNS name of the RKE2 API, added to the certificate SANs. Null uses the load balancers' own DNS names."
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
  description = "EC2 instance type of the control-plane nodes. Null uses m7i.xlarge."
}

variable "control_plane_disk_size_gb" {
  type        = number
  default     = null
  description = "Root volume size in GB of the control-plane nodes. Null uses 100."
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
  description = "GPU worker pools keyed by pool name. On aws only instance_type, count, disk_size_gb and zone are supported."
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

variable "jumphost_instance_type" {
  type        = string
  default     = null
  description = "EC2 instance type of the build host. Null uses c6i.xlarge; the Marketplace image rejects 7th-generation types."
}

variable "jumphost_disk_size_gb" {
  type        = number
  default     = null
  description = "Root volume size in GB of the build host. Null uses 100."
}

variable "image_id" {
  type        = string
  default     = null
  description = "Existing AMI to boot instead of building one. Must not be an AMI this module registered."
}

variable "keep_build_artifacts" {
  type        = bool
  default     = false
  description = "Keep the raw image in S3 instead of expiring it a day after upload."
}

variable "aif_release" {
  type        = string
  default     = "2.3.0"
  description = "AI Factory release: a manifest URL (http:// or https://), or a version X.Y.Z resolved to the tag aif-operator-<version>."
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
  description = "Crypt hash of the root password (`openssl passwd -6`)."
}

variable "node_username" {
  type        = string
  default     = "suse"
  description = "Unprivileged login on every node. The image has no sudo; use `su -`."
}

variable "node_user_password_hash" {
  type        = string
  sensitive   = true
  description = "Crypt hash of the node_username password."
}

variable "ssh_authorized_keys" {
  type        = list(string)
  description = "SSH public keys for node_username and the build host."
}

variable "permit_root_ssh" {
  type        = bool
  default     = false
  description = "Allow SSH as root on the nodes (debug)."
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
  description = "NGC username paired with nvidia_api_key."
}

variable "gpu_driver_repository" {
  type        = string
  default     = "registry.opensuse.org/home/eminguez/branches/home/avicenzi/nvidia-for-bci-161/containerfile/third-party/nvidia"
  description = "Registry path of the precompiled NVIDIA driver container."
}

variable "gpu_driver_version" {
  type        = string
  default     = "615"
  description = "NVIDIA driver branch under gpu_driver_repository."
}

variable "rancher_hostname" {
  type        = string
  default     = null
  description = "Hostname of the Rancher ingress. Null uses the public NLB DNS name."
}

variable "rancher_bootstrap_password" {
  type        = string
  default     = null
  sensitive   = true
  description = "Rancher initial admin password. Null generates one."
}

variable "image_rebuild" {
  type        = number
  default     = 0
  description = "Rebuild counter mixed into the image build hash. deploy.sh --rebuild bumps it in rebuild.auto.tfvars.json; do not set it by hand or in terraform.tfvars."
}

variable "vmimport_role_name" {
  type        = string
  default     = null
  description = "Name of a pre-created IAM role for the snapshot import. Set together with jumphost_instance_profile_name; null makes the module create both."
}

variable "jumphost_instance_profile_name" {
  type        = string
  default     = null
  description = "Name of a pre-created instance profile for the build host. Set together with vmimport_role_name; null makes the module create both."
}
