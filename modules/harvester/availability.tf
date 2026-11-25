# Plan-time checks. Harvester has no quota API and the provider cannot read host
# capacity, so a VM that does not fit is found at launch. What can be read is
# checked here: the network, the StorageClass and any image the inputs name.
# Reading a missing object fails the plan. The provider has no namespace data
# source: a missing harvester_namespace fails at the first create.

data "harvester_network" "this" {
  name      = local.network_name
  namespace = local.network_namespace
}

data "harvester_storageclass" "this" {
  count = var.storage_class_name != null ? 1 : 0

  name = var.storage_class_name
}

# A malformed reference skips the lookup so the precondition below reports it.
locals {
  image_ref_format = "^[a-z0-9]([a-z0-9.-]*[a-z0-9])?/[a-z0-9]([a-z0-9.-]*[a-z0-9])?$"

  buildhost_image_ok = var.jumphost_image != null && can(regex(local.image_ref_format, var.jumphost_image))
  node_image_ok      = var.image_id != null && can(regex(local.image_ref_format, var.image_id))
}

data "harvester_image" "buildhost" {
  count = local.buildhost_image_ok ? 1 : 0

  name      = split("/", var.jumphost_image)[1]
  namespace = split("/", var.jumphost_image)[0]
}

data "harvester_image" "node" {
  count = local.node_image_ok ? 1 : 0

  name      = split("/", var.image_id)[1]
  namespace = split("/", var.image_id)[0]
}

locals {
  vip_inputs = { api_vip = var.api_vip, ingress_vip = var.ingress_vip }
  # An address is usable when it is inside vpc_cidr and is neither the network nor the broadcast address.
  # Inside means: the same prefix length around the address gives vpc_cidr's network address.
  vip_inside = {
    for k, v in local.vip_inputs : k => try(
      cidrhost(format("%s/%s", v, split("/", local.vpc_cidr)[1]), 0) == cidrhost(local.vpc_cidr, 0), false
    )
  }
  vip_outside = sort([for k, inside in local.vip_inside : k if !inside])
  vip_reserved = sort([for k, v in local.vip_inputs : k
    if local.vip_inside[k] && (v == cidrhost(local.vpc_cidr, 0) || v == cidrhost(local.vpc_cidr, -1))
  ])

  # Every gpu_pools key and "cp" can have a device entry; a gpu pool without one would boot without its GPUs.
  gpu_missing = sort([for k, p in var.gpu_pools : k if p.count > 0 && !contains(keys(var.gpu_devices), k)])
  gpu_unknown = sort([for k in keys(var.gpu_devices) : k if k != "cp" && !contains(keys(var.gpu_pools), k)])

  # A root disk cannot be smaller than its image: the built image is as large as the target volume.
  node_image_gib = local.build_image ? local.image_disk_gib : ceil(try(data.harvester_image.node[0].size, 0) / 1073741824)
  disk_too_small = sort(distinct([for n in local.ignition_nodes : n.who if n.disk_size_gb < local.node_image_gib]))
}

# Plan-time input checks; every resource depends on this one.
resource "terraform_data" "input_checks" {
  # The lookups above fail the plan when an object is missing; recording them keeps them in the graph.
  input = {
    network       = data.harvester_network.this.id
    storage_class = one(data.harvester_storageclass.this[*].id)
  }

  lifecycle {
    precondition {
      condition     = var.vpc_cidr != null
      error_message = "vpc_cidr is required: set it to the subnet of the network ${var.vpc_id} (the VIPs and node addresses must lie inside it)."
    }

    # Accepted but not enforced (VLAN networks have no security groups); still validated as CIDR blocks.
    precondition {
      condition     = alltrue([for c in concat(var.admin_cidrs, var.api_cidrs, var.ingress_cidrs) : can(cidrhost(c, 0))])
      error_message = "admin_cidrs, api_cidrs and ingress_cidrs must be CIDR blocks with an explicit prefix. They are not enforced on Harvester."
    }

    precondition {
      condition     = !var.control_plane_public_ip
      error_message = "control_plane_public_ip must be false: VMs attach to a VLAN network and have no public IP."
    }

    precondition {
      condition     = alltrue([for k, p in local.agent_pools : !p.public_ip])
      error_message = "worker_pools and gpu_pools public_ip must be false: VMs attach to a VLAN network and have no public IP."
    }

    precondition {
      condition     = alltrue([for k, p in local.agent_pools : p.placement == null])
      error_message = "worker_pools and gpu_pools placement must be null: placement groups are not supported."
    }

    precondition {
      condition     = alltrue([for k, p in local.agent_pools : p.kind == "vm"])
      error_message = "gpu_pools and worker_pools support kind = \"vm\" only: Harvester has no bare metal instances."
    }

    precondition {
      condition     = alltrue([for k, p in local.agent_pools : p.zone == null])
      error_message = "A pool zone must be null: Harvester has no zones."
    }

    precondition {
      condition     = length(var.zones) == 0
      error_message = "zones must be empty: Harvester has no zones."
    }

    precondition {
      condition     = length(local.size_errors) == 0
      error_message = "Invalid instance types: ${join("; ", local.size_errors)}."
    }

    precondition {
      condition     = var.vpc_cidr == null || (tonumber(split("/", local.vpc_cidr)[1]) >= 16 && tonumber(split("/", local.vpc_cidr)[1]) <= 29)
      error_message = "vpc_cidr must be between a /16 and a /29: it is the real subnet of the network."
    }

    precondition {
      condition     = local.vpc_mtu <= 9000
      error_message = "vpc_mtu must be at most 9000."
    }

    precondition {
      condition     = var.vpc_cidr == null || length(local.vip_outside) == 0
      error_message = "${join(" and ", local.vip_outside)} must lie inside vpc_cidr ${local.vpc_cidr}."
    }

    precondition {
      condition     = length(local.vip_reserved) == 0
      error_message = "${join(" and ", local.vip_reserved)} is the network or broadcast address of vpc_cidr ${local.vpc_cidr}."
    }

    precondition {
      condition     = length(local.gpu_missing) == 0
      error_message = "gpu_devices has no entry for gpu_pools ${jsonencode(local.gpu_missing)}: set device_name (for example \"nvidia.com/GA102GL_A10\") and count per node."
    }

    precondition {
      condition     = length(local.disk_too_small) == 0
      error_message = "Root disks of ${join(", ", local.disk_too_small)} are smaller than the node image (${local.node_image_gib} GiB): raise their disk size or lower image_disk_size."
    }

    precondition {
      condition     = length(local.gpu_unknown) == 0
      error_message = "gpu_devices keys ${jsonencode(local.gpu_unknown)} are not gpu_pools keys or \"cp\"."
    }

    precondition {
      condition     = var.jumphost_image == null || can(regex(local.image_ref_format, var.jumphost_image))
      error_message = "jumphost_image must be an existing image as <namespace>/<name>."
    }

    precondition {
      condition     = var.image_id == null || can(regex(local.image_ref_format, var.image_id))
      error_message = "image_id must be an existing image as <namespace>/<name>."
    }

    precondition {
      condition     = var.jumphost_image == null || try(data.harvester_image.buildhost[0].state, "Active") == "Active"
      error_message = "The buildhost image ${coalesce(var.jumphost_image, "-")} is not ready (state ${try(data.harvester_image.buildhost[0].state, "-")})."
    }

    precondition {
      condition     = var.image_id == null || try(data.harvester_image.node[0].state, "Active") == "Active"
      error_message = "The node image ${coalesce(var.image_id, "-")} is not ready (state ${try(data.harvester_image.node[0].state, "-")})."
    }

    precondition {
      condition     = length(local.storage_class_unknown) == 0
      error_message = "node_storage_classes keys ${jsonencode(local.storage_class_unknown)} are not \"cp\", \"buildhost\" or a gpu_pools/worker_pools key."
    }

    precondition {
      condition     = var.image_id == null || length(local.node_class_overrides) == 0
      error_message = "node_storage_classes sets node classes, which need exports of a built image: it cannot be combined with image_id."
    }

    precondition {
      condition     = var.jumphost_image == null || !contains(keys(var.node_storage_classes), "buildhost")
      error_message = "node_storage_classes[\"buildhost\"] applies to the downloaded buildhost image; with jumphost_image the disk uses that image's class."
    }

    precondition {
      condition     = length(var.tags) == 0 || alltrue([for k, v in var.tags : !strcontains(k, "/")])
      error_message = "tags keys must not contain \"/\": they become Kubernetes label keys."
    }
  }
}

# Longhorn serves ReadWriteMany through its NFS share manager unless the class
# is migratable, and a VM block disk cannot use that: non-migratable classes
# get ReadWriteOnce. Disks from an image follow the image's class parameters.
locals {
  # The buildhost image is downloaded onto this class; ignored with jumphost_image.
  buildhost_class = lookup(var.node_storage_classes, "buildhost", var.storage_class_name)

  # Named classes other than storage_class_name: each is read for its parameters.
  extra_classes = setunion(
    local.extra_node_classes,
    local.buildhost_class != null && local.buildhost_class != var.storage_class_name ? [local.buildhost_class] : [],
  )
}

data "harvester_storageclass" "extra" {
  for_each = local.extra_classes

  name = each.key
}

locals {
  sc_migratable = var.storage_class_name == null ? true : lookup(try(data.harvester_storageclass.this[0].parameters, {}), "migratable", "false") == "true"

  # null is the cluster default class (migratable on Harvester).
  class_migratable = merge(
    { for c in local.extra_classes : c => lookup(try(data.harvester_storageclass.extra[c].parameters, {}), "migratable", "false") == "true" },
    var.storage_class_name == null ? {} : { (var.storage_class_name) = local.sc_migratable },
  )

  buildhost_disk_migratable = (var.jumphost_image != null
    ? lookup(try(data.harvester_image.buildhost[0].storage_class_parameters, {}), "migratable", "false") == "true"
    : local.buildhost_class == null ? true : local.class_migratable[local.buildhost_class]
  )
  node_disk_migratable = {
    for h, c in local.node_class : h => (var.image_id != null
      ? lookup(try(data.harvester_image.node[0].storage_class_parameters, {}), "migratable", "false") == "true"
      : c == null ? true : local.class_migratable[c]
    )
  }

  target_access_mode    = local.sc_migratable ? "ReadWriteMany" : "ReadWriteOnce"
  buildhost_access_mode = local.buildhost_disk_migratable ? "ReadWriteMany" : "ReadWriteOnce"
  node_access_mode      = { for h, m in local.node_disk_migratable : h => m ? "ReadWriteMany" : "ReadWriteOnce" }

  storage_class_keys    = setunion(["cp", "buildhost"], keys(var.gpu_pools), keys(var.worker_pools))
  storage_class_unknown = sort([for k in keys(var.node_storage_classes) : k if !contains(local.storage_class_keys, k)])
  node_class_overrides  = [for k in keys(var.node_storage_classes) : k if k != "buildhost"]
}
