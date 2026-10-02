# evroc-only variables. Common variables live in variables-common.tf.

variable "project" {
  type        = string
  default     = null
  description = "evroc project to create resources in. Null uses the project of the provider's configured context."
}

variable "image_ids" {
  type        = map(string)
  default     = {}
  description = "Existing evroc snapshots to boot instead of building images, keyed by zone; snapshots are zonal, so it must cover every zone in use. Empty builds one image per zone."
}

variable "image_ready" {
  type        = bool
  default     = false
  description = "Set by deploy.sh for the second pass, once the per-zone image builds have finished. false attaches the blank image disks to the build hosts; true detaches them and snapshots them."
}

variable "image_target_disk_gb" {
  type        = number
  default     = 32
  description = "Size in GB of the blank disk each build host writes the raw image onto. Must be at least image_disk_size."

  validation {
    condition = var.image_target_disk_gb >= ceil(
      tonumber(substr(var.image_disk_size, 0, length(var.image_disk_size) - 1)) *
      lookup({ K = 1 / 1048576, M = 1 / 1024, G = 1, T = 1024 }, substr(var.image_disk_size, -1, 1), 0)
    )
    error_message = "image_target_disk_gb (${var.image_target_disk_gb}) must be at least the size image_disk_size (${var.image_disk_size}) requests."
  }
}
