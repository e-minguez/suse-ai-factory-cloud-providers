# Control planes and agents from the gallery image, in the private subnet without
# a public IP, one VM per node keyed by hostname. No Azure agent: the baked
# azure-report-ready unit reports the VM up (ADR 015).

locals {
  node_user_data = { for n in local.ignition_nodes : n.hostname => base64encode(module.config.node_runtime_ignition[n.hostname]) }

  nodes = var.deploy_nodes ? { for n in local.ignition_nodes : n.hostname => n } : {}

  node_tags = {
    for n in local.ignition_nodes : n.hostname => merge(local.labels, {
      "elemental-role"  = n.role
      "elemental-pool"  = n.pool
      "elemental-build" = module.config.build_id
    })
  }
}

resource "azurerm_network_interface" "node" {
  for_each = local.nodes

  name                           = "${each.key}-nic"
  location                       = local.region
  resource_group_name            = local.resource_group_name
  accelerated_networking_enabled = try(local.sku_info[each.value.instance_type].accel, false)
  tags                           = local.node_tags[each.key]

  ip_configuration {
    name                          = "internal"
    subnet_id                     = local.private_subnet_id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface_security_group_association" "node" {
  for_each = local.nodes

  network_interface_id      = azurerm_network_interface.node[each.key].id
  network_security_group_id = azurerm_network_security_group.this[each.value.role == "control_plane" ? "control_plane" : "agent"].id
}

resource "azurerm_network_interface_application_security_group_association" "node" {
  for_each = local.nodes

  network_interface_id          = azurerm_network_interface.node[each.key].id
  application_security_group_id = azurerm_application_security_group.this[each.value.role == "control_plane" ? "control_plane" : "agent"].id
}

# Control planes are the backends of every load balancer rule.
resource "azurerm_network_interface_backend_address_pool_association" "control_plane" {
  for_each = { for h, n in local.nodes : h => n if n.role == "control_plane" }

  network_interface_id    = azurerm_network_interface.node[each.key].id
  ip_configuration_name   = "internal"
  backend_address_pool_id = azurerm_lb_backend_address_pool.control_plane.id
}

resource "azurerm_linux_virtual_machine" "node" {
  for_each = local.nodes

  depends_on = [
    terraform_data.limits_check,
    azurerm_network_interface_security_group_association.node,
    azurerm_network_interface_application_security_group_association.node,
    azurerm_network_interface_backend_address_pool_association.control_plane,
  ]

  name                  = each.key
  location              = local.region
  resource_group_name   = local.resource_group_name
  size                  = each.value.instance_type
  zone                  = each.value.zone
  network_interface_ids = [azurerm_network_interface.node[each.key].id]
  source_image_id       = local.effective_image_id
  user_data             = local.node_user_data[each.key]
  disk_controller_type  = try(local.disk_controller[each.value.instance_type], "SCSI")
  tags                  = local.node_tags[each.key]

  # The OS profile is required but ignored by the image: Ignition creates the
  # user from the baked butane config. No agent, no extensions.
  admin_username                  = var.node_username
  disable_password_authentication = true
  provision_vm_agent              = false
  allow_extension_operations      = false

  admin_ssh_key {
    username   = var.node_username
    public_key = var.ssh_authorized_keys[0]
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = local.os_disk_type
    disk_size_gb         = each.value.disk_size_gb
  }

  # Security type Standard, stated: the image is not Trusted Launch capable.
  secure_boot_enabled = false
  vtpm_enabled        = false

  boot_diagnostics {}

  # Ignition runs on first boot only: a changed user_data reaches new nodes only.
  # A new image replaces the node.
  lifecycle {
    ignore_changes       = [user_data]
    replace_triggered_by = [terraform_data.build_trigger, terraform_data.node_image]

    precondition {
      condition     = local.effective_image_id != null
      error_message = "No image: set image_id or leave it null to build one."
    }
  }
}

# With build_trigger, replaces every node when the image changes (built or image_id).
resource "terraform_data" "node_image" {
  input = local.effective_image_id
}
