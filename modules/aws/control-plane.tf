# Control-plane nodes, launched from the AMI in image.tf. Keyed by hostname so
# changing the count adds or removes only the nodes whose hostnames change.
resource "aws_instance" "control_plane" {
  # Low max_retries: a capacity shortage fails instead of retrying (docs/workarounds.md).
  provider = aws.nodes

  # Instance type offered in the zone (availability.tf).
  depends_on = [data.aws_ec2_instance_type_offerings.this]

  for_each = var.deploy_nodes ? { for n in local.control_plane_nodes : n.hostname => n } : {}

  ami           = local.effective_ami_id
  instance_type = each.value.instance_type

  # Private subnet, no public IP. The static address is known at plan time
  # (locals.tf), so each node's Ignition can hardcode its node-ip.
  subnet_id  = aws_subnet.private[each.value.subnet_index].id
  private_ip = each.value.private_ip

  vpc_security_group_ids = [aws_security_group.control_plane.id]

  # Nodes call no AWS API, so they get no instance profile.

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
      "elemental-role"  = "control_plane"
      "elemental-pool"  = each.value.pool
      "elemental-build" = module.elemental_config.build_id
    })
  }

  # No ignore_changes on ami: a new build_id replaces every node.

  # The build label is set per resource, not in common_tags (cycle through the load balancers).
  tags = merge(local.common_tags, {
    Name              = each.key
    "elemental-role"  = "control_plane"
    "elemental-pool"  = each.value.pool
    "elemental-build" = module.elemental_config.build_id
  })
}
