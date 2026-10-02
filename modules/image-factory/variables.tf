variable "elemental_image" {
  type        = string
  description = "OCI image that runs elemental3ctl customize."
}

variable "build_id" {
  type        = string
  description = "Build identifier (first 12 characters of build_hash); written to the done marker and exposed to hooks as BUILD_ID."
}

variable "config_dir" {
  type        = string
  default     = "/var/lib/elemental-config"
  description = "Directory on the build host holding the Elemental config, including release_manifest.yaml. Mounted at /config in the build container."
}

variable "log_file" {
  type        = string
  default     = "/var/log/elemental-factory.log"
  description = "Build host file that receives all script output. scripts/build-logs.sh follows the default path."
}

variable "state_dir" {
  type        = string
  default     = "/var/lib/image-factory"
  description = "Build host directory for the done marker (state_dir/done contains build_id after a successful build)."
}

variable "extra_packages" {
  type        = list(string)
  default     = []
  description = "Packages installed in addition to podman and curl. Each must provide a command of the same name; the script fails when one is missing afterwards."
}

variable "customize_attempts" {
  type        = number
  default     = 3
  description = "Attempts for elemental customize; registry errors mid-build are transient."

  validation {
    condition     = var.customize_attempts >= 1
    error_message = "customize_attempts must be at least 1."
  }
}

variable "customize_retry_delay" {
  type        = number
  default     = 60
  description = "Seconds to wait between customize attempts."
}

variable "hook_is_already_built" {
  type        = string
  default     = "return 1"
  description = "Bash body of is_already_built. Return 0 when the output already exists; the script then skips the build and exits 0."
}

variable "hook_pre_build" {
  type        = string
  default     = ":"
  description = "Bash body of pre_build, run after package install and before is_already_built (install tools, open ports, fetch config)."
}

variable "hook_on_step" {
  type        = string
  default     = ":"
  description = "Bash body of on_step. Receives $1 = step name (prereqs, pre_build, check, customize, locate, deliver, finished, failed) and $2 = text."
}

variable "hook_deliver_raw" {
  type        = string
  default     = "return 0"
  description = "Bash body of deliver_raw. Receives $1 = path of the raw image and moves it to its destination."
}

variable "hook_on_exit" {
  type        = string
  default     = ":"
  description = "Bash body of on_exit, run from the EXIT trap. Receives $1 = exit status."
}
