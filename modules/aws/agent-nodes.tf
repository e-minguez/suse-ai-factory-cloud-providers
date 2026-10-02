# Worker and GPU nodes from the same AMI as the control plane. Keyed by hostname,
# DHCP addresses: growing one pool does not replace nodes in another. The image has no DKMS:
# the GPU operator uses precompiled driver containers (docs/workarounds.md).
resource "aws_instance" "agent" {
  # Low max_retries: a capacity shortage fails instead of retrying (docs/workarounds.md).
  provider = aws.nodes

  # Instance type offered in the zone (availability.tf).
  depends_on = [data.aws_ec2_instance_type_offerings.this]

  for_each = var.deploy_nodes ? { for n in local.agent_nodes : n.hostname => n } : {}

  ami           = local.effective_ami_id
  instance_type = each.value.instance_type

  subnet_id  = aws_subnet.private[each.value.subnet_index].id
  private_ip = each.value.private_ip

  # one() because the group exists only when a worker or GPU pool does, as this resource.
  vpc_security_group_ids = [one(aws_security_group.agent[*].id)]

  user_data = module.elemental_config.node_runtime_ignition[each.key]

  # Ignition runs on first boot only: a changed user_data (e.g. suse_storage_nodes)
  # reaches new nodes only. A new image still replaces the node.
  lifecycle {
    ignore_changes = [user_data]
  }

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size           = each.value.disk_size_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true

    tags = merge(local.common_tags, {
      Name              = "${each.key}-root"
      "elemental-role"  = each.value.role
      "elemental-pool"  = each.value.pool
      "elemental-build" = module.elemental_config.build_id
    })
  }

  # No ignore_changes on ami: a new build_id replaces every node.

  tags = merge(local.common_tags, {
    Name              = each.key
    "elemental-role"  = each.value.role
    "elemental-pool"  = each.value.pool
    "elemental-build" = module.elemental_config.build_id
  })
}
