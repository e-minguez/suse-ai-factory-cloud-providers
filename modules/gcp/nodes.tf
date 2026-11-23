# Control planes and agents (GPU and worker pools) from the image, in the
# subnet without a public address unless requested. Keyed by hostname, so
# changing a count adds or removes only the nodes whose hostnames change. Nodes
# hold no service account: they read no object storage and call no Google API.

locals {
  # One metadata value holds 262144 bytes; user_data_max_bytes (image.tf) keeps
  # the node Ignition below it. The budget here is the same check on the final value.
  node_metadata_budget = 262144 - 12288

  node_user_data = { for n in local.ignition_nodes : n.hostname => module.config.node_runtime_ignition[n.hostname] }

  nodes = var.deploy_nodes ? { for n in local.ignition_nodes : n.hostname => n } : {}

  # nonsensitive() on the hostnames only, so the error can name the node.
  oversized_user_data = nonsensitive(sort([for h, d in local.node_user_data : h if var.deploy_nodes && length(d) >= local.node_metadata_budget]))

  node_labels = {
    for n in local.ignition_nodes : n.hostname => merge(local.labels, {
      "elemental-role"  = n.role
      "elemental-pool"  = n.pool
      "elemental-build" = module.config.build_id
    })
  }
}

resource "google_compute_instance" "node" {
  for_each = local.nodes

  # Quota and machine type checks gate the launch.
  depends_on = [terraform_data.limits_check]

  name         = each.key
  zone         = each.value.zone
  machine_type = each.value.instance_type
  tags         = [local.tags[each.value.role == "control_plane" ? "control_plane" : "agent"]]
  labels       = local.node_labels[each.key]

  boot_disk {
    interface = local.boot_disk_interface[each.value.instance_type]

    initialize_params {
      image  = local.effective_image_id
      size   = each.value.disk_size_gb
      type   = local.node_boot_disk_type[each.value.instance_type]
      labels = local.node_labels[each.key]
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.this.id
    nic_type   = "GVNIC"

    dynamic "access_config" {
      for_each = each.value.public_ip ? [1] : []

      content {}
    }
  }

  # Ignition reads the user-data attribute of the metadata server.
  metadata = {
    user-data = local.node_user_data[each.key]
  }

  # GPU families cannot live-migrate: the host maintenance event stops the VM.
  scheduling {
    on_host_maintenance = each.value.role == "gpu" || contains(local.gpu_families, local.machine_family[each.value.instance_type]) ? "TERMINATE" : "MIGRATE"
    automatic_restart   = true
  }

  shielded_instance_config {
    enable_secure_boot = false
  }

  # Ignition runs on first boot only: a changed user_data reaches new nodes only.
  # A new image replaces the node, whatever the provider would do in place.
  lifecycle {
    ignore_changes       = [metadata]
    replace_triggered_by = [terraform_data.build_trigger, terraform_data.node_image]

    precondition {
      condition     = length(local.oversized_user_data) == 0
      error_message = "Node metadata is over the budget of ${local.node_metadata_budget} characters for ${join(", ", local.oversized_user_data)} (a metadata value holds 262144 bytes). Look for unusually large ssh_authorized_keys (RSA keys run 700+ bytes each; ed25519 keys are ~80), or oversized credential values."
    }
  }
}

# With build_trigger, replaces every node when the image changes (built or image_id).
resource "terraform_data" "node_image" {
  input = local.effective_image_id
}
