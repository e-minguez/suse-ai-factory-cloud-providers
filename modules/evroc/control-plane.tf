# Control-plane VMs: boot disk cloned from the node's own zone's snapshot,
# optional public IP, keyed by hostname so a growing pool never renumbers a node.

locals {
  # Uses snapshot_expected, not snapshot ids, so for_each keys stay plan-known (image.tf).
  control_plane_deploy_gate = var.deploy_nodes && local.snapshot_expected

  # Keys depend only on plan-known variables, never on the snapshot id.
  control_plane_nodes_map = local.control_plane_deploy_gate ? {
    for node in local.control_plane_nodes : node.hostname => node
  } : {}
}

resource "evroc_disk" "control_plane" {
  for_each = local.control_plane_nodes_map

  name = "${each.key}-boot"
  # Same zone as the VM.
  zone = each.value.zone
  # Snapshot of the node's own zone.
  snapshot = local.effective_snapshot_ids[each.value.zone]
  size     = local.control_plane_disk_size_gb
  project  = var.project
  region   = var.region

  # build_labels: snapshots cannot be labelled, so the build shows on the clone.
  user_labels = merge(local.build_labels, {
    "elemental-role" = "control_plane"
    "elemental-pool" = "cp"
  })

  timeouts {
    create = local.disk_create_timeout
    delete = local.disk_delete_timeout
  }
}

resource "evroc_public_ip" "control_plane" {
  for_each = var.control_plane_public_ip ? local.control_plane_nodes_map : {}

  name    = "${each.key}-ip"
  project = var.project
  region  = var.region

  # common_labels: an address is not tied to an image generation.
  user_labels = merge(local.common_labels, {
    "elemental-role" = "control_plane"
    "elemental-pool" = "cp"
  })
}

resource "evroc_virtual_machine" "control_plane" {
  # Flavor offered by the platform (availability.tf).
  depends_on = [data.evroc_compute_profiles.this]

  for_each = local.control_plane_nodes_map

  name    = each.key
  flavor  = local.control_plane_instance_type
  zone    = each.value.zone
  project = var.project
  region  = var.region

  boot_disk       = evroc_disk.control_plane[each.key].name
  security_groups = [evroc_security_group.control_plane.fqid]
  # Zonal placement group and subnet of the node's zone; the security group is regional.
  placement_group = evroc_placement_group.control_plane[each.value.zone].fqid
  subnet_ref      = evroc_subnet.this[each.value.zone].fqid
  public_ip       = try(evroc_public_ip.control_plane[each.key].name, null)

  # Per-node Ignition (hostname, role) from the config module; it also fails
  # the plan when a node exceeds the user_data limit.
  cloud_config_user_data = module.config.node_runtime_ignition[each.key]

  # Ignition runs on first boot only: a changed user_data (e.g. suse_storage_nodes)
  # reaches new nodes only. A new image still replaces the node.
  lifecycle {
    ignore_changes = [cloud_config_user_data]
  }

  # The elemental image is EFI-only; without the UEFI label (an experimental
  # platform feature flag) the VM boots BIOS and hangs as "Running". build_labels
  # shows which image a node booted.
  user_labels = merge(local.build_labels, {
    "elemental-role"                     = "control_plane"
    "elemental-pool"                     = "cp"
    "compute-experimental-features-UEFI" = "true"
  })
}

locals {
  # Backend refs for the load balancer pool (loadbalancer.tf); empty before nodes exist.
  control_plane_fqids = [for vm in evroc_virtual_machine.control_plane : vm.fqid]
}
