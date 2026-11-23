# Provider-only variables. Common variables live in variables-common.tf
# (symlink to modules/common/variables-common.tf). The root module configures
# the google provider and its credentials (Application Default Credentials).

variable "gcp_project" {
  type        = string
  description = "ID of the Google Cloud project that holds every resource of the cluster; the module builds its Compute API URLs from it."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.gcp_project))
    error_message = "gcp_project must be a project ID (6-30 characters: lowercase letters, digits and hyphens, starting with a letter), not the project name or number."
  }
}

variable "boot_disk_type" {
  type        = string
  default     = null
  description = "Boot disk type of the cluster nodes (for example pd-ssd or hyperdisk-balanced). Null picks one per machine family: pd-balanced, or hyperdisk-balanced for C3, C4, N4, G4 and A3 and later. The jumphost always uses the family default."

  validation {
    condition     = var.boot_disk_type == null || can(regex("^(pd-(standard|balanced|ssd)|hyperdisk-(balanced|extreme|throughput))$", coalesce(var.boot_disk_type, "x")))
    error_message = "boot_disk_type must be pd-standard, pd-balanced, pd-ssd, hyperdisk-balanced, hyperdisk-extreme or hyperdisk-throughput."
  }
}
