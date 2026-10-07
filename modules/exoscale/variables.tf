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
