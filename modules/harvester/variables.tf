# Provider-only variables. Common variables live in variables-common.tf
# (symlink to modules/common/variables-common.tf). The root module configures
# the harvester provider (kubeconfig).

variable "harvester_namespace" {
  type        = string
  description = "Existing namespace that holds every object of the cluster (VMs, volumes, images, secrets). The module does not create it."

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.harvester_namespace))
    error_message = "harvester_namespace must be a valid namespace name: lowercase alphanumerics and hyphens."
  }
}

variable "vpc_id" {
  type        = string
  description = "Existing Harvester VM network as <namespace>/<name>, for example \"harvester-public/vlan-2006\". It needs DHCP and egress; vpc_cidr must be its subnet."

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9.-]*[a-z0-9])?/[a-z0-9]([a-z0-9.-]*[a-z0-9])?$", var.vpc_id))
    error_message = "vpc_id must be <namespace>/<name> of a Harvester VM network."
  }
}

variable "api_vip" {
  type        = string
  description = "Static IPv4 of the Kubernetes API (ports 6443 and 9345), held by MetalLB. Inside vpc_cidr, outside the DHCP range, different from ingress_vip."

  validation {
    condition     = can(regex("^((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])$", var.api_vip))
    error_message = "api_vip must be a valid IPv4 address."
  }
}

variable "ingress_vip" {
  type        = string
  description = "Static IPv4 of the ingress controller (80 and 443), held by MetalLB. Inside vpc_cidr, outside the DHCP range, different from api_vip."

  validation {
    condition     = can(regex("^((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\\.){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])$", var.ingress_vip))
    error_message = "ingress_vip must be a valid IPv4 address."
  }

  validation {
    condition     = var.ingress_vip != var.api_vip
    error_message = "api_vip and ingress_vip must be different addresses."
  }
}

variable "storage_class_name" {
  type        = string
  default     = null
  description = "StorageClass for the image target volume and the images; null uses the cluster default. Disks created from an image always use that image's own StorageClass."
}

variable "disk_cache_mode" {
  type        = string
  default     = null
  description = "KubeVirt cache mode of the node root disks: none, writethrough or writeback; null keeps the Harvester default. writeback speeds up writes but keeps guest flushes, so etcd fsync latency barely changes."

  validation {
    condition     = var.disk_cache_mode == null || contains(["none", "writethrough", "writeback"], coalesce(var.disk_cache_mode, "-"))
    error_message = "disk_cache_mode must be none, writethrough or writeback (KubeVirt has no unsafe mode; see etcd_unsafe_no_fsync)."
  }
}

variable "node_storage_classes" {
  type        = map(string)
  default     = {}
  description = "StorageClass per node group, keyed by \"cp\" (control planes), a gpu_pools or worker_pools key, or \"buildhost\"; the rest use storage_class_name. Every extra class gets its own export of the node image (no clone without encryption)."
}

variable "buildhost_power_off" {
  type        = bool
  default     = true
  description = "Power the buildhost off once the image is written and Terraform has read the done status. It only builds: nodes are reached directly on the VM network."
}

variable "buildhost_image_url" {
  type        = string
  default     = "https://download.opensuse.org/distribution/leap/16.0/appliances/Leap-16.0-Minimal-VM.x86_64-Cloud.qcow2"
  description = "qcow2 or raw image Harvester downloads for the buildhost when jumphost_image is null. It needs cloud-init, qemu-guest-agent and zypper."

  validation {
    condition     = can(regex("^https?://", var.buildhost_image_url))
    error_message = "buildhost_image_url must be an http or https URL."
  }
}

variable "gpu_devices" {
  type = map(object({
    device_name = string
    count       = optional(number, 1)
  }))
  default     = {}
  description = "Host devices per node, keyed by gpu_pools key or \"cp\" (every control plane): the KubeVirt resource name, for example \"nvidia.com/GA102GL_A10\", and the devices per node. Every gpu_pools key needs an entry."

  validation {
    condition     = alltrue([for k, d in var.gpu_devices : d.count >= 1 && d.count == floor(d.count) && trimspace(d.device_name) != ""])
    error_message = "Every gpu_devices entry needs a device_name and a whole count of at least 1."
  }
}
