variable "mgmt" {
  type = object({
    cluster_name = string
    rancher_url  = string
  })
  description = "Management cluster: name and Rancher URL, taken from its outputs by cluster.sh (TF_VAR_mgmt)."

  validation {
    condition     = can(regex("^https://", var.mgmt.rancher_url))
    error_message = "mgmt.rancher_url must be an https:// URL; the management cluster needs Rancher enabled."
  }
}

variable "downstream" {
  type = map(object({
    cluster_name = string
    provider     = string
    egress_ips   = list(string)
  }))
  default     = {}
  description = "Clusters to import, keyed by clusters/<name> directory; cluster.sh fills it from their outputs (TF_VAR_downstream)."

  validation {
    condition     = alltrue([for d in var.downstream : can(regex("^[a-z][a-z0-9-]{0,62}$", d.cluster_name))])
    error_message = "Every downstream cluster_name must be lowercase letters, digits and dashes, starting with a letter."
  }
}

variable "rancher_token" {
  type        = string
  default     = null
  sensitive   = true
  description = "Rancher API token (access:secret). Null reads RANCHER_TOKEN_KEY from the environment. Set it in clusters/common-register.tfvars, never in the repo."
}

variable "rancher_insecure" {
  type        = bool
  default     = true
  description = "Skip TLS verification of the Rancher URL. The default Rancher certificate is issued by a private CA."
}

variable "bootstrap" {
  type        = bool
  default     = false
  description = "Log in with the first-login bootstrap password and use the admin token it creates, instead of rancher_token."
}

variable "bootstrap_password" {
  type        = string
  default     = null
  sensitive   = true
  description = "Rancher bootstrap password, passed by cluster.sh from the management cluster outputs (TF_VAR_bootstrap_password). Only used with bootstrap = true."
}
