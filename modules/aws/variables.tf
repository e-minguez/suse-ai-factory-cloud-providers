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
