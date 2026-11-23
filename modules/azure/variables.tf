# Provider-only variables. Common variables live in variables-common.tf
# (symlink to modules/common/variables-common.tf). The root module configures
# the azurerm and azapi providers and their credentials.

variable "azure_subscription_id" {
  type        = string
  description = "ID of the subscription that holds every resource of the cluster."

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.azure_subscription_id))
    error_message = "azure_subscription_id must be a subscription GUID."
  }
}

variable "resource_group_name" {
  type        = string
  default     = null
  description = "Existing resource group for the cluster's resources. Null creates a group named after cluster_name; the module deletes only a group it created."
}

variable "vpc_id" {
  type        = string
  default     = null
  description = "Resource ID of an existing virtual network to deploy into instead of creating one. Requires public_subnet_id and private_subnet_id; vpc_cidr must be null or one of its address spaces."

  validation {
    condition     = var.vpc_id == null || can(regex("(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.Network/virtualNetworks/[^/]+$", var.vpc_id))
    error_message = "vpc_id must be a virtual network resource ID (/subscriptions/.../providers/Microsoft.Network/virtualNetworks/<name>)."
  }
}

variable "public_subnet_id" {
  type        = string
  default     = null
  description = "Existing subnet of vpc_id for the jumphost, which gets a public IP. Required with vpc_id."

  validation {
    condition     = (var.public_subnet_id == null) == (var.vpc_id == null)
    error_message = "vpc_id, public_subnet_id and private_subnet_id must be set together."
  }

  validation {
    condition     = var.public_subnet_id == null || can(regex("(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.Network/virtualNetworks/[^/]+/subnets/[^/]+$", var.public_subnet_id))
    error_message = "public_subnet_id must be a subnet resource ID (.../virtualNetworks/<vnet>/subnets/<name>)."
  }
}

variable "private_subnet_id" {
  type        = string
  default     = null
  description = "Existing subnet of vpc_id for the nodes, with outbound access through a NAT gateway that has a public IP; that address becomes the cluster egress IP. Required with vpc_id."

  validation {
    condition     = (var.private_subnet_id == null) == (var.vpc_id == null)
    error_message = "vpc_id, public_subnet_id and private_subnet_id must be set together."
  }

  validation {
    condition     = var.private_subnet_id == null || can(regex("(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.Network/virtualNetworks/[^/]+/subnets/[^/]+$", var.private_subnet_id))
    error_message = "private_subnet_id must be a subnet resource ID (.../virtualNetworks/<vnet>/subnets/<name>)."
  }

  validation {
    condition     = var.private_subnet_id == null || lower(var.private_subnet_id) != lower(coalesce(var.public_subnet_id, "+"))
    error_message = "public_subnet_id and private_subnet_id must be different subnets."
  }
}
