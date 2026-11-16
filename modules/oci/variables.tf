# Provider-only variables. Common variables live in variables-common.tf
# (symlink to modules/common/variables-common.tf). The root module configures
# the oci provider and its API-key credentials.

variable "oci_tenancy_ocid" {
  type        = string
  description = "OCID of the tenancy; its availability domains are resolved from it."
}

variable "oci_compartment_ocid" {
  type        = string
  description = "OCID of the compartment that holds every resource of the cluster."
}

variable "vpc_id" {
  type        = string
  default     = null
  description = "OCID of an existing VCN to deploy into instead of creating one. Requires public_subnet_id and private_subnet_id; vpc_cidr must be null or one of the VCN CIDR blocks."

  validation {
    condition     = var.vpc_id == null || can(regex("^ocid1\\.vcn\\.", var.vpc_id))
    error_message = "vpc_id must be a VCN OCID (ocid1.vcn...)."
  }
}

variable "public_subnet_id" {
  type        = string
  default     = null
  description = "Existing regional subnet of vpc_id that allows public IPs and routes 0.0.0.0/0 to an internet gateway: jumphost and network load balancer. Required with vpc_id."

  validation {
    condition     = (var.public_subnet_id == null) == (var.vpc_id == null)
    error_message = "vpc_id, public_subnet_id and private_subnet_id must be set together."
  }

  validation {
    condition     = var.public_subnet_id == null || can(regex("^ocid1\\.subnet\\.", var.public_subnet_id))
    error_message = "public_subnet_id must be a subnet OCID (ocid1.subnet...)."
  }
}

variable "private_subnet_id" {
  type        = string
  default     = null
  description = "Existing regional subnet of vpc_id that routes 0.0.0.0/0 to a NAT gateway: nodes. Its NAT address becomes the cluster egress IP. Required with vpc_id."

  validation {
    condition     = (var.private_subnet_id == null) == (var.vpc_id == null)
    error_message = "vpc_id, public_subnet_id and private_subnet_id must be set together."
  }

  validation {
    condition     = var.private_subnet_id == null || can(regex("^ocid1\\.subnet\\.", var.private_subnet_id))
    error_message = "private_subnet_id must be a subnet OCID (ocid1.subnet...)."
  }

  validation {
    condition     = var.private_subnet_id == null || var.private_subnet_id != var.public_subnet_id
    error_message = "public_subnet_id and private_subnet_id must be different subnets."
  }
}
