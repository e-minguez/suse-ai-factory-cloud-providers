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

variable "vpc_id" {
  type        = string
  default     = null
  description = "Existing VPC network (name or self link) in gcp_project to deploy into instead of creating one. Requires subnet_id; the module then creates no VPC, subnet, Cloud Router or Cloud NAT."

  validation {
    condition     = var.vpc_id == null || can(regex("^(?:(?:https://www\\.googleapis\\.com/compute/v1/)?projects/[a-z][a-z0-9-]*[a-z0-9]/global/networks/)?[a-z](?:[-a-z0-9]*[a-z0-9])?$", var.vpc_id))
    error_message = "vpc_id must be a VPC network name or self link (projects/<project>/global/networks/<name>)."
  }
}

variable "subnet_id" {
  type        = string
  default     = null
  description = "Existing regional subnet of vpc_id in region (name or self link) for every node and the jumphost. It needs Cloud NAT egress, because nodes are private. Required with vpc_id."

  validation {
    condition     = var.subnet_id == null || can(regex("^(?:(?:https://www\\.googleapis\\.com/compute/v1/)?projects/[a-z][a-z0-9-]*[a-z0-9]/regions/[a-z0-9-]+/subnetworks/)?[a-z](?:[-a-z0-9]*[a-z0-9])?$", var.subnet_id))
    error_message = "subnet_id must be a subnet name or self link (projects/<project>/regions/<region>/subnetworks/<name>)."
  }

  validation {
    condition     = (var.subnet_id == null) == (var.vpc_id == null)
    error_message = "vpc_id and subnet_id must be set together."
  }
}

variable "nat_ips" {
  type        = list(string)
  default     = []
  description = "Public addresses of the Cloud NAT serving subnet_id, for the egress_ips output and the firewall rules that admit nodes to the external load balancer. Cloud NAT cannot be read back, so list them; empty skips both. Only with vpc_id."

  validation {
    condition     = alltrue([for c in var.nat_ips : can(cidrhost("${c}/32", 0))])
    error_message = "nat_ips must be IPv4 addresses."
  }

  validation {
    condition     = length(var.nat_ips) == 0 || var.vpc_id != null
    error_message = "nat_ips applies only with vpc_id: without it the module reserves the NAT address."
  }
}
