# Worker and GPU agents: standalone instances with per-node Ignition, from the
# same template as the control plane. for_each keyed by hostname, so growing
# one pool never renumbers another. No inbound rules: they are reached over the
# private network (dynamic lease); the public IP serves egress and metadata.
resource "exoscale_compute_instance" "agent" {
  for_each = var.deploy_nodes ? { for n in local.agent_nodes : n.hostname => n } : {}

  depends_on = [terraform_data.api_check]

  zone        = local.zone
  name        = each.key
  template_id = local.effective_template_id
  type        = each.value.instance_type
  disk_size   = each.value.disk_size_gb

  security_group_ids = [exoscale_security_group.agent.id]

  labels = merge(local.labels, {
    "elemental-role"  = each.value.role
    "elemental-pool"  = each.value.pool
    "elemental-build" = module.config.build_id
  })

  network_interface {
    network_id = exoscale_private_network.this.id
  }

  # Raw Ignition JSON (ignition.platform.id=exoscale), merged over the image's
  # base config: only per-node data (hostname, runtime.env).
  user_data = module.config.node_runtime_ignition[each.key]

  # Ignition runs on first boot only: a changed user_data (e.g. suse_storage_nodes)
  # reaches new nodes only. A new image still replaces the node.
  lifecycle {
    ignore_changes = [user_data]
  }
}

locals {
  agent_private_ip = { for h, a in exoscale_compute_instance.agent : h => one([for ni in a.network_interface : ni.ip_address]) }
}
