# Control planes and agents (GPU and worker pools) from the exported image, one
# NIC on the VM network. Keyed by hostname, so changing a count adds or removes
# only the nodes whose hostnames change.
# Addresses come from DHCP; the image's qemu-guest-agent (started by udev)
# reports them, so apply waits for the lease.

locals {
  nodes = var.deploy_nodes ? { for n in local.ignition_nodes : n.hostname => n } : {}

  node_tags = {
    for n in local.ignition_nodes : n.hostname => merge(local.labels, {
      "elemental-role"  = n.role
      "elemental-pool"  = n.pool
      "elemental-build" = module.config.build_id
    })
  }
}

# NoCloud: Harvester stores user_data under the key "userdata"; Ignition reads it as is.
resource "harvester_cloudinit_secret" "node" {
  for_each = local.nodes

  depends_on = [terraform_data.input_checks]

  name      = each.key
  namespace = var.harvester_namespace
  user_data = module.config.node_runtime_ignition[each.key]
  labels    = local.node_tags[each.key]

  lifecycle {
    replace_triggered_by = [terraform_data.build_trigger, terraform_data.node_image[each.key]]
  }
}

resource "harvester_virtualmachine" "node" {
  for_each = local.nodes

  depends_on = [terraform_data.input_checks]

  name         = each.key
  namespace    = var.harvester_namespace
  hostname     = each.key
  description  = "${each.value.role} node of ${var.cluster_name}"
  labels       = local.node_tags[each.key]
  cpu          = local.sizes[each.value.instance_type].cpu
  memory       = "${local.sizes[each.value.instance_type].memory}Gi"
  efi          = true
  secure_boot  = false
  machine_type = "q35"

  network_interface {
    name           = "nic-1"
    network_name   = var.vpc_id
    mac_address    = local.macs[each.key]
    wait_for_lease = true
  }

  disk {
    name        = "rootdisk"
    type        = "disk"
    bus         = "virtio"
    boot_order  = 1
    size        = "${each.value.disk_size_gb}Gi"
    image       = local.node_image_id[each.key]
    auto_delete = true
    access_mode = local.node_access_mode[each.key]
    cache_mode  = var.disk_cache_mode
  }

  dynamic "host_device" {
    for_each = local.node_host_devices[each.key]

    content {
      name        = host_device.value.name
      device_name = host_device.value.device_name
    }
  }

  cloudinit {
    type                  = "noCloud"
    user_data_secret_name = harvester_cloudinit_secret.node[each.key].name
  }

  # The first boot takes 5-7 minutes (root volume copy, recovery install, reboot)
  # before the agent reports the lease.
  timeouts {
    create = "30m"
  }

  # Ignition runs on first boot only: a new image or build replaces the node.
  lifecycle {
    replace_triggered_by = [terraform_data.build_trigger, terraform_data.node_image[each.key]]
  }
}

# With build_trigger, replaces a node when its image changes (new build,
# image_id, or another StorageClass for its group).
resource "terraform_data" "node_image" {
  for_each = local.nodes

  input = local.node_image_id[each.key]
}
