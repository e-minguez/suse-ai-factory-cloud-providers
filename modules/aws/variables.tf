# Inputs not shared with the other providers. Every other input is declared in
# variables-common.tf (symlink to modules/common/variables-common.tf).

variable "vmimport_role_name" {
  type        = string
  default     = null
  description = "Name of a pre-created IAM role for the snapshot import (docs/providers/aws.md#pre-created-iam). Set together with jumphost_instance_profile_name; null makes the module create both."

  validation {
    condition     = (var.vmimport_role_name == null) == (var.jumphost_instance_profile_name == null)
    error_message = "vmimport_role_name and jumphost_instance_profile_name must both be set or both be null."
  }

  validation {
    condition     = var.vmimport_role_name != ""
    error_message = "vmimport_role_name must not be empty; use null to let the module create the IAM roles."
  }
}

variable "jumphost_instance_profile_name" {
  type        = string
  default     = null
  description = "Name of a pre-created instance profile for the build host. Set together with vmimport_role_name; null makes the module create both."

  validation {
    condition     = var.jumphost_instance_profile_name != ""
    error_message = "jumphost_instance_profile_name must not be empty; use null to let the module create the IAM roles."
  }
}

variable "vpc_id" {
  type        = string
  default     = null
  description = "ID of an existing VPC in region to deploy into instead of creating one. Requires public_subnet_ids and private_subnet_ids; vpc_cidr must be null or equal to the VPC primary CIDR."
}

variable "public_subnet_ids" {
  type        = map(string)
  default     = {}
  description = "Existing public subnets of vpc_id keyed by zone suffix (\"a\", \"b\"), routed to an internet gateway: jumphost and public NLB. Required with vpc_id."

  validation {
    condition     = (length(var.public_subnet_ids) == 0) == (var.vpc_id == null)
    error_message = "vpc_id, public_subnet_ids and private_subnet_ids must be set together."
  }
}

variable "private_subnet_ids" {
  type        = map(string)
  default     = {}
  description = "Existing private subnets of vpc_id keyed by zone suffix, with a default route that is not an internet gateway (NAT gateway, transit gateway): nodes and internal NLB. Required with vpc_id; empty zones defaults to its keys."

  validation {
    condition     = (length(var.private_subnet_ids) == 0) == (var.vpc_id == null)
    error_message = "vpc_id, public_subnet_ids and private_subnet_ids must be set together."
  }

  validation {
    condition     = toset(keys(var.private_subnet_ids)) == toset(keys(var.public_subnet_ids))
    error_message = "public_subnet_ids and private_subnet_ids need the same zones: one public and one private subnet per zone."
  }

  validation {
    condition     = length(var.private_subnet_ids) == 0 || length(var.zones) == 0 || toset(var.zones) == toset(keys(var.private_subnet_ids))
    error_message = "private_subnet_ids and public_subnet_ids need exactly one entry per zone in zones (${join(", ", var.zones)}); they have ${join(", ", sort(keys(var.private_subnet_ids)))}."
  }
}
