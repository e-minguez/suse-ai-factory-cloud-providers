# Provider-only variables. Common variables live in variables-common.tf
# (symlink to modules/common/variables-common.tf).

variable "exoscale_api_key" {
  type        = string
  sensitive   = true
  description = "Exoscale API key for the signed plan-time checks and the control plane member lookup. The root module also passes it to the exoscale provider."
}

variable "exoscale_api_secret" {
  type        = string
  sensitive   = true
  description = "Secret of exoscale_api_key."
}

variable "cp_initialized" {
  type        = bool
  default     = false
  description = "The control plane pool's first member has bootstrapped the cluster. false renders the init configuration with pool size 1; true renders the join configuration and scales to control_plane_count. deploy.sh sets it after pass 1 (docs/decisions/008-exoscale-module.md)."
}

variable "image_import_port_open" {
  type        = bool
  default     = true
  description = "Allow tcp/80 from anywhere on the jumphost so Exoscale can fetch the qcow2 image. deploy.sh sets it to false on pass 2, once the template exists."
}

variable "network_mode" {
  type        = string
  default     = "public"
  description = "How nodes reach each other. \"public\": over their public IPv4, restricted by security group rules (temporary mode, until VPC works with instance pools and the NLB); \"private_network\": a classic private network (stops working on 2027-05-03, not available to new organizations)."

  validation {
    condition     = contains(["public", "private_network"], var.network_mode)
    error_message = "network_mode must be \"public\" or \"private_network\"."
  }
}
