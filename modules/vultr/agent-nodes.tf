# Worker and GPU agents, from the same snapshot as the control plane, in two resource
# families that can be mixed in one cluster. The hostname is what the elemental
# config keys the "agent" role off, in both cases.
#
# for_each keyed by hostname, so growing one pool never renumbers another.

# --- Bare metal (vbm-* plans) -------------------------------------------------
#
# No firewall_group_id: Vultr offers no firewall for bare metal, so the public
# IP of these nodes is unfiltered at the platform level. Cloud pools (kind =
# "vm") take a firewall group. See docs/providers/vultr.md#security.
resource "vultr_bare_metal_server" "agent" {
  for_each = var.deploy_nodes ? { for n in local.agent_bare_metal_nodes : n.hostname => n } : {}

  depends_on = [data.http.plan_availability]

  region      = var.region
  plan        = each.value.plan
  snapshot_id = local.effective_snapshot_id

  # Singular vpc_id here; vultr_instance takes vpc_ids.
  vpc_id = vultr_vpc.this.id

  label    = each.key
  hostname = each.key

  tags             = local.node_tags[each.key]
  ssh_key_ids      = var.ssh_key_ids
  enable_ipv6      = local.enable_ipv6
  mdisk_mode       = var.mdisk_mode
  activation_email = local.activation_email

  # Raw Ignition JSON, not cloud-init; same mechanism as control-plane.tf.
  user_data = module.config.node_runtime_ignition[each.key]

  # Ignition runs on first boot only: a changed user_data (e.g. suse_storage_nodes)
  # reaches new nodes only. A new image still replaces the node.
  lifecycle {
    ignore_changes = [user_data]
  }
}

# --- Cloud (vultr_instance, the vcg-* plans) ----------------------------------
#
# Same image and Ignition mechanism as bare metal. vpc_only and
# firewall_group_id exist on this resource, so a cloud agent is either
# firewalled or has no public NIC and egresses through the NAT gateway.
#
# No mdisk_mode: vultr_instance has no equivalent.
resource "vultr_instance" "agent_cloud" {
  for_each = var.deploy_nodes ? { for n in local.agent_cloud_nodes : n.hostname => n } : {}

  # Stock check, and the NAT gateway: a vpc_only instance has no other route out.
  depends_on = [
    data.http.plan_availability,
    vultr_nat_gateway.this,
  ]

  region      = var.region
  plan        = each.value.plan
  snapshot_id = local.effective_snapshot_id

  vpc_only = each.value.vpc_only
  vpc_ids  = [vultr_vpc.this.id]

  firewall_group_id = one(vultr_firewall_group.agent_cloud[*].id)

  label    = each.key
  hostname = each.key

  tags             = local.node_tags[each.key]
  activation_email = local.activation_email

  # A vpc_only node has no public NIC for either to attach to.
  ssh_key_ids = each.value.vpc_only ? [] : var.ssh_key_ids
  enable_ipv6 = each.value.vpc_only ? false : local.enable_ipv6

  # Raw Ignition JSON, not cloud-init. The node-ip drop-in is written at first
  # boot by write-node-ip.service, on a dual-NIC node only (control-plane.tf).
  user_data = module.config.node_runtime_ignition[each.key]

  # Ignition runs on first boot only: a changed user_data (e.g. suse_storage_nodes)
  # reaches new nodes only. A new image still replaces the node.
  lifecycle {
    ignore_changes = [user_data]
  }
}
