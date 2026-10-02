# Agent VMs across var.worker_pools and var.gpu_pools (role worker / gpu): same
# shape as control-plane.tf, with per-pool zone (default zones[0]), placement
# group and public IP. See docs/decisions/004-evroc-module-rationale.md.

locals {
  # Same gate as control-plane.tf: snapshot_expected keeps for_each keys plan-known.
  agent_nodes_deploy_gate = var.deploy_nodes && local.snapshot_expected

  # Keyed by hostname; keys are plan-known, never derived from the snapshot id.
  agent_nodes_map = local.agent_nodes_deploy_gate ? {
    for node in local.agent_nodes : node.hostname => node
  } : {}
}

resource "evroc_disk" "agent" {
  for_each = local.agent_nodes_map

  name = "${each.key}-boot"
  # Same zone as the VM.
  zone = each.value.zone
  # Snapshot of the node's own zone.
  snapshot = local.effective_snapshot_ids[each.value.zone]
  size     = each.value.disk_size_gb
  project  = var.project
  region   = var.region

  # As control-plane.tf, plus `pool`.
  user_labels = merge(local.build_labels, {
    "elemental-role" = each.value.role
    "elemental-pool" = each.value.pool
  })

  timeouts {
    create = local.disk_create_timeout
    delete = local.disk_delete_timeout
  }
}

resource "evroc_public_ip" "agent" {
  for_each = { for k, n in local.agent_nodes_map : k => n if n.public_ip }

  name    = "${each.key}-ip"
  project = var.project
  region  = var.region

  user_labels = merge(local.common_labels, {
    "elemental-role" = each.value.role
    "elemental-pool" = each.value.pool
  })
}

resource "evroc_virtual_machine" "agent" {
  # Flavor offered by the platform (availability.tf).
  depends_on = [data.evroc_compute_profiles.this]

  for_each = local.agent_nodes_map

  name    = each.key
  flavor  = each.value.instance_type
  zone    = each.value.zone
  project = var.project
  region  = var.region

  boot_disk = evroc_disk.agent[each.key].name
  # The worker group exists exactly when any pool is defined, as does agent_nodes_map.
  security_groups = [one(evroc_security_group.agent[*].fqid)]
  subnet_ref      = evroc_subnet.this[each.value.zone].fqid
  # null means no public IP.
  public_ip = try(evroc_public_ip.agent[each.key].name, null)

  # null means no placement group; the key is rebuilt as in locals.tf's agent_placement_groups.
  placement_group = try(evroc_placement_group.agent["${each.value.pool}/${each.value.zone}"].fqid, null)

  # Per-node Ignition (module.config.node_runtime_ignition): agent role and,
  # for suse_storage_nodes, the Longhorn disk label.
  cloud_config_user_data = module.config.node_runtime_ignition[each.key]

  # Ignition runs on first boot only: a changed user_data (e.g. suse_storage_nodes)
  # reaches new nodes only. A new image still replaces the node.
  lifecycle {
    ignore_changes = [cloud_config_user_data]
  }

  # UEFI label as in control-plane.tf.
  user_labels = merge(local.build_labels, {
    "elemental-role"                     = each.value.role
    "elemental-pool"                     = each.value.pool
    "compute-experimental-features-UEFI" = "true"
  })
}
