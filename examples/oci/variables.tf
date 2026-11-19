# Only variables a user sets. Everything else keeps the module default; see
# modules/oci/variables.tf and modules/common/variables-common.tf.

# --- Common ---------------------------------------------------------------

variable "cluster_name" {
  type        = string
  default     = "suse-ai-factory"
  description = "Prefix of resource names and node hostnames."
}

variable "region" {
  type        = string
  default     = "eu-frankfurt-1"
  description = "OCI region to deploy into, for example \"eu-frankfurt-1\". It must be one the tenancy is subscribed to."
}

variable "zones" {
  type        = list(string)
  default     = []
  description = "Availability domains to span, as lowercase short names, for example [\"ad-1\"]. Empty uses the first one."
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
  description = "CIDRs allowed to reach the ingress listeners on 80/443."
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
  description = "Shape of the control-plane nodes; flex shapes take a size, for example \"VM.Standard.E5.Flex:4x32\" (OCPUs x GB). Null uses that value."
}

variable "control_plane_public_ip" {
  type        = bool
  default     = false
  description = "Give the control-plane nodes a public IP. Nodes are not deployed by this module version yet."
}

variable "jumphost_instance_type" {
  type        = string
  default     = null
  description = "Shape of the jumphost, same syntax as control_plane_instance_type. Null uses \"VM.Standard.E5.Flex:2x16\"."
}

variable "jumphost_image" {
  type        = string
  default     = null
  description = "OCID of the jumphost image. Null uses the newest Oracle Linux 9 platform image."
}

variable "jumphost_username" {
  type        = string
  default     = "suse"
  description = "Login user of the jumphost. Empty makes the jumphost root-only."
}

variable "keep_build_artifacts" {
  type        = bool
  default     = false
  description = "Keep the qcow2 in the build bucket after the image is imported; delete it before destroy."
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
  description = "GPU worker pools keyed by pool name, with VM GPU shapes such as VM.GPU.A10.1. Bare metal shapes are not supported."
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
  description = "Existing image OCID to boot instead of building one. Null builds the image."
}

variable "aif_release" {
  type        = string
  default     = "2.4.0"
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
  description = "Rancher hostname. Null derives rancher-<load balancer IP>.sslip.io."
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

# --- OCI ------------------------------------------------------------------

variable "oci_tenancy_ocid" {
  type        = string
  description = "OCID of the tenancy."
}

variable "oci_user_ocid" {
  type        = string
  description = "OCID of the user that owns the API key."
}

variable "oci_fingerprint" {
  type        = string
  description = "Fingerprint of the API key."
}

variable "oci_private_key_path" {
  type        = string
  description = "Path of the API signing private key (PEM)."
}

variable "oci_compartment_ocid" {
  type        = string
  description = "OCID of the compartment that holds the cluster."
}

variable "image_rebuild" {
  type        = number
  default     = 0
  description = "Rebuild counter mixed into the image build hash. deploy.sh --rebuild bumps it in rebuild.auto.tfvars.json; do not set it by hand or in terraform.tfvars."
}

variable "vpc_id" {
  type        = string
  default     = null
  description = "OCID of an existing VCN to deploy into. Requires public_subnet_id and private_subnet_id; null creates the VCN, subnets, gateways and routes."
}

variable "public_subnet_id" {
  type        = string
  default     = null
  description = "Existing regional subnet of vpc_id that allows public IPs and routes to an internet gateway. Required with vpc_id."
}

variable "private_subnet_id" {
  type        = string
  default     = null
  description = "Existing regional subnet of vpc_id that routes to a NAT gateway. Required with vpc_id."
}

variable "vpc_cidr" {
  type        = string
  default     = null
  description = "IPv4 CIDR of the VCN. Null uses 10.20.0.0/20, or with vpc_id the first CIDR block of the existing VCN."
}

variable "control_plane_disk_size_gb" {
  type        = number
  default     = null
  description = "Boot volume size in GB of the control-plane nodes. Null uses 100."
}

variable "jumphost_disk_size_gb" {
  type        = number
  default     = null
  description = "Boot volume size in GB of the jumphost. Null uses 100."
}

variable "etcd_unsafe_no_fsync" {
  type        = bool
  default     = false
  description = "DANGEROUS: disables fsync in etcd (etcd --unsafe-no-fsync), so a host crash or power loss can corrupt etcd and lose the cluster. Only for throwaway clusters on disks too slow for etcd."
}
