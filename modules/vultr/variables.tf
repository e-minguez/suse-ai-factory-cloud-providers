# Provider-only variables. Common variables live in variables-common.tf
# (symlink to modules/common/variables-common.tf).

variable "vultr_api_key" {
  type        = string
  sensitive   = true
  description = "Vultr API key for the plan-time stock checks, load balancer address lookups and the wait scripts. The root module also passes it to the vultr provider."
}

variable "ssh_key_ids" {
  type        = list(string)
  default     = []
  description = "Vultr SSH key IDs injected into the jumphost and every node that has a public NIC."
}

variable "mdisk_mode" {
  type        = string
  default     = "none"
  description = "Managed disk mode of bare metal agent nodes (raid1, jbod or none). Applies to gpu_pools and worker_pools entries with kind = \"bare_metal\" only."

  validation {
    condition     = contains(["raid1", "jbod", "none"], var.mdisk_mode)
    error_message = "mdisk_mode must be one of: raid1, jbod, none."
  }
}

variable "agent_cloud_extra_cidrs" {
  type        = list(string)
  default     = []
  description = "Extra CIDRs allowed on the RKE2 ports of cloud agent nodes (GPU and worker pools), beyond the VPC CIDR. deploy.sh fills it from the nat_gateway_public_cidrs value on pass 2."
}

variable "lb_supervisor_extra_cidrs" {
  type        = list(string)
  default     = []
  description = "Extra CIDRs allowed to reach the load balancer on 9345, typically the public /32s of agent nodes. deploy.sh fills it from the agent_node_cidrs value on pass 2."
}

variable "lb_backend_instance_ids" {
  type        = list(string)
  default     = []
  description = "Instance IDs attached to the load balancers as backends. Empty on pass 1 and filled from control_plane_ids on pass 2, because a reference would close a dependency cycle with the image build."
}

variable "image_import_port_open" {
  type        = bool
  default     = true
  description = "Allow tcp/80 from anywhere on the jumphost so Vultr can fetch the raw image. deploy.sh sets it to false on pass 2, once the snapshot is complete."
}
