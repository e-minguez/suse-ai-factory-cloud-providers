# Image target volume -> node images. The buildhost (build.tf) only writes the
# volume; Terraform exports it, so `terraform destroy` removes the images. The
# exports run while the buildhost still holds the volume. An image_id pinned
# that way must not be one this module owns.

# A disk from an image must use the image's StorageClass, and Harvester clones
# images only to encrypt or decrypt them: every StorageClass the nodes use gets
# its own export. "default" is storage_class_name; other keys are class names.
locals {
  node_class = {
    for n in local.ignition_nodes : n.hostname => lookup(var.node_storage_classes, n.pool, var.storage_class_name)
  }
  extra_node_classes = toset([for h, c in local.node_class : c if c != null && c != var.storage_class_name])
  node_image_classes = merge({ default = var.storage_class_name }, { for c in local.extra_node_classes : c => c })
  node_image_key     = { for h, c in local.node_class : h => c == var.storage_class_name ? "default" : c }
}

resource "harvester_image" "node" {
  for_each = local.build_image ? local.node_image_classes : {}

  depends_on = [terraform_data.image_ready]

  name               = each.key == "default" ? local.image_base : "${local.image_base}-${substr(sha1(each.key), 0, 8)}"
  namespace          = var.harvester_namespace
  display_name       = each.key == "default" ? local.image_base : "${local.image_base}-${each.key}"
  source_type        = "export-from-volume"
  pvc_name           = harvester_volume.image_target[0].name
  pvc_namespace      = var.harvester_namespace
  storage_class_name = each.value
  labels = merge(local.labels, {
    "elemental-role"  = "image"
    "elemental-build" = module.config.build_id
  })

  timeouts {
    create = "60m"
  }
}

# The single node image of earlier versions is the "default" export.
moved {
  from = harvester_image.node[0]
  to   = harvester_image.node["default"]
}

locals {
  # Empty when image_id is set (no export).
  effective_image_id = var.image_id != null ? var.image_id : try(harvester_image.node["default"].id, null)
  node_image_id = {
    for h, k in local.node_image_key : h => var.image_id != null ? var.image_id : try(harvester_image.node[k].id, null)
  }
  node_images = var.image_id != null ? { default = var.image_id } : { for k, i in harvester_image.node : k => i.id }
}
