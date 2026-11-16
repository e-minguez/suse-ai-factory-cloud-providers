# Control planes and agents (GPU and worker pools) from the imported image, in
# the private subnet without a public IP. Keyed by hostname, so changing a count
# adds or removes only the nodes whose hostnames change.

locals {
  # Metadata is capped at 32000 bytes; the budget counts the base64 text.
  node_metadata_budget = 32000 - 1024

  node_ssh_keys = join("\n", var.ssh_authorized_keys)

  node_user_data = { for n in local.ignition_nodes : n.hostname => base64encode(module.config.node_runtime_ignition[n.hostname]) }

  nodes = var.deploy_nodes ? { for n in local.ignition_nodes : n.hostname => n } : {}

  node_shapes = { for h, n in local.nodes : h => local.shapes[n.instance_type] }

  # nonsensitive() on the hostnames only, so the error can name the node.
  oversized_user_data = nonsensitive(sort([for h, d in local.node_user_data : h if var.deploy_nodes && length(d) + length(local.node_ssh_keys) >= local.node_metadata_budget]))
}

resource "oci_core_instance" "node" {
  for_each = local.nodes

  # Capability schema and shape compatibility belong to the image; quota and
  # shape checks gate the launch.
  depends_on = [
    terraform_data.limits_check,
    oci_core_compute_image_capability_schema.uefi,
    oci_core_shape_management.gpu,
  ]

  compartment_id      = var.oci_compartment_ocid
  availability_domain = local.ad_names[each.value.zone]
  fault_domain        = each.value.fault_domain
  display_name        = each.key
  shape               = local.node_shapes[each.key].name

  dynamic "shape_config" {
    for_each = local.node_shapes[each.key].flex ? [1] : []

    content {
      ocpus         = local.node_shapes[each.key].ocpus
      memory_in_gbs = local.node_shapes[each.key].memory
    }
  }

  source_details {
    source_type             = "image"
    source_id               = local.effective_image_id
    boot_volume_size_in_gbs = each.value.disk_size_gb
  }

  create_vnic_details {
    subnet_id        = local.private_subnet_id
    assign_public_ip = false
    nsg_ids          = [local.nsg_ids[each.value.role == "control_plane" ? "control_plane" : "agent"]]
    display_name     = each.key
    freeform_tags    = local.node_tags[each.key]
  }

  # Ignition reads user_data from /opc/v2/; the v1 endpoints are not needed.
  instance_options {
    are_legacy_imds_endpoints_disabled = true
  }

  metadata = {
    user_data           = local.node_user_data[each.key]
    ssh_authorized_keys = local.node_ssh_keys
  }

  preserve_boot_volume = false
  freeform_tags        = local.node_tags[each.key]

  # Ignition runs on first boot only: a changed user_data reaches new nodes only.
  # A new image replaces the node: the provider would swap the boot volume in place.
  lifecycle {
    ignore_changes       = [metadata]
    replace_triggered_by = [terraform_data.build_trigger, terraform_data.node_image]

    precondition {
      condition     = length(local.oversized_user_data) == 0
      error_message = "Node metadata is over the budget of ${local.node_metadata_budget} characters for ${join(", ", local.oversized_user_data)} (OCI allows 32000 bytes of metadata). Look for unusually large ssh_authorized_keys (RSA keys run 700+ bytes each; ed25519 keys are ~80), or oversized credential values."
    }
  }
}

locals {
  node_tags = {
    for n in local.ignition_nodes : n.hostname => merge(local.labels, {
      "elemental-role"  = n.role
      "elemental-pool"  = n.pool
      "elemental-build" = module.config.build_id
    })
  }
}

# With build_trigger, replaces every node when the image changes (built or image_id).
resource "terraform_data" "node_image" {
  input = local.effective_image_id
}
