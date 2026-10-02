# vpc_only control-plane nodes, built from the snapshot the jumphost produces.
#
# count keys off plan-known variables, never off local.effective_snapshot_id:
# on a first build or a rebuild that is unknown until apply, even though it
# feeds this resource's own snapshot_id.
resource "vultr_instance" "control_plane" {
  count = var.deploy_nodes ? var.control_plane_count : 0

  # Stock check, and the NAT gateway: a vpc_only instance has no other route out.
  depends_on = [data.http.plan_availability, vultr_nat_gateway.this]

  region      = var.region
  plan        = local.control_plane_plan
  snapshot_id = local.effective_snapshot_id

  # No public NIC. Egress is the NAT gateway; the jumphost is the only way in.
  vpc_only = true
  vpc_ids  = [vultr_vpc.this.id]

  firewall_group_id = vultr_firewall_group.control_plane.id

  label    = local.control_plane_nodes[count.index].hostname
  hostname = local.control_plane_nodes[count.index].hostname

  tags = local.node_tags[local.control_plane_nodes[count.index].hostname]

  # Raw Ignition JSON (ignition.platform.id=vultr), merged over the image's
  # base config: only per-node data (hostname, runtime.env, RKE2 manifests).
  # write-node-ip.service writes nothing on a single-NIC node, so RKE2 keeps its
  # DHCP address, which is the one the load balancers have on file.
  user_data = module.config.node_runtime_ignition[local.control_plane_nodes[count.index].hostname]

  # Ignition runs on first boot only: a changed user_data (e.g. suse_storage_nodes)
  # reaches new nodes only. A new image still replaces the node.
  lifecycle {
    ignore_changes = [user_data]
  }
}
