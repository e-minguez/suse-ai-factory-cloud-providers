# Jumphost and build host: builds the raw image, converts it to a fixed VHD and
# uploads it as a page blob through a write-only container SAS, so it holds no
# Azure credentials. It stays as the SSH bastion into the private nodes: with
# image_id set it exists only while nodes are deployed and builds nothing. The
# gallery image is created in image.tf.

locals {
  build_image = var.image_id == null
  # The nodes are private: the jumphost is their only SSH entry.
  jumphost_enabled = local.build_image || var.deploy_nodes

  # Storage account names are 3-24 lowercase alphanumerics and global; this one
  # is stable per subscription and cluster.
  storage_account_name = "aif${substr(sha1("${var.azure_subscription_id}/${var.cluster_name}"), 0, 12)}"
  container_name       = "images"
  container_url        = "https://${local.storage_account_name}.blob.core.windows.net/${local.container_name}"
  vhd_name             = "${local.image_base}.vhd"
  done_name            = "${local.image_base}.done"

  # Values derived from the build hash are placeholders in the shared script, so
  # its script_hash (a build_hash input) is static. The stripped script ships in custom_data.
  build_id_placeholder   = "@@BUILD_ID@@"
  sas_placeholder        = "@@WRITE_SAS@@"
  image_base_placeholder = "${var.cluster_name}-${local.build_id_placeholder}"

  factory_script = replace(
    replace(
      replace(module.image_factory.script_stripped, local.image_base_placeholder, local.image_base),
      local.sas_placeholder, local.build_image ? local.write_sas : ""
    ),
    local.build_id_placeholder, module.config.build_id
  )
}

# The blob names and the SAS tokens depend on build_hash, so the tokens are
# per build; the window stays fixed for a build (no plan drift).
resource "time_offset" "sas_start" {
  count = local.build_image ? 1 : 0

  offset_minutes = -15 # clock skew
  triggers       = { build = module.config.build_hash }
}

resource "time_offset" "sas_expiry" {
  count = local.build_image ? 1 : 0

  offset_hours = local.sas_expiry_hours
  triggers     = { build = module.config.build_hash }
}

# Page blob target of the upload. Shared key access must be allowed on the
# account: the SAS tokens are signed with it.
resource "azurerm_storage_account" "build" {
  count = local.build_image ? 1 : 0

  depends_on = [terraform_data.limits_check]

  name                            = local.storage_account_name
  location                        = local.region
  resource_group_name             = local.resource_group_name
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = true
  tags                            = merge(local.labels, { "elemental-role" = "image" })
}

resource "azurerm_storage_container" "images" {
  count = local.build_image ? 1 : 0

  name                  = local.container_name
  storage_account_id    = azurerm_storage_account.build[0].id
  container_access_type = "private"
}

# Create and write allow a PUT of a blob and its pages and nothing else (no
# read, list or delete). The token is a secret until it expires.
data "azurerm_storage_account_blob_container_sas" "write" {
  count = local.build_image ? 1 : 0

  connection_string = azurerm_storage_account.build[0].primary_connection_string
  container_name    = azurerm_storage_container.images[0].name
  https_only        = true
  start             = time_offset.sas_start[0].rfc3339
  expiry            = time_offset.sas_expiry[0].rfc3339

  permissions {
    read   = false
    add    = false
    create = true
    write  = true
    delete = false
    list   = false
  }
}

# Terraform polls the done marker with this one and deletes the VHD with it
# once the gallery image exists.
data "azurerm_storage_account_blob_container_sas" "operator" {
  count = local.build_image ? 1 : 0

  connection_string = azurerm_storage_account.build[0].primary_connection_string
  container_name    = azurerm_storage_container.images[0].name
  https_only        = true
  start             = time_offset.sas_start[0].rfc3339
  expiry            = time_offset.sas_expiry[0].rfc3339

  permissions {
    read   = true
    add    = false
    create = false
    write  = false
    delete = true
    list   = false
  }
}

locals {
  write_sas    = local.build_image ? sensitive(trimprefix(data.azurerm_storage_account_blob_container_sas.write[0].sas, "?")) : ""
  operator_sas = local.build_image ? sensitive(trimprefix(data.azurerm_storage_account_blob_container_sas.operator[0].sas, "?")) : ""
  done_url     = local.build_image ? sensitive("${local.container_url}/${local.done_name}?${local.operator_sas}") : null
  vhd_url      = local.build_image ? sensitive("${local.container_url}/${local.vhd_name}?${local.operator_sas}") : null
}

# Builds the raw with podman, converts it to a fixed VHD and uploads it
# (templates/factory/): the shared image-factory script plus provider hooks. The
# marketplace SLES image installs podman and qemu-tools with zypper and ships curl.
module "image_factory" {
  source = "../image-factory"

  elemental_image = var.elemental_image
  build_id        = local.build_id_placeholder
  config_dir      = local.config_dir
  log_file        = "/var/log/elemental-factory.log"

  hook_pre_build = file("${path.module}/templates/factory/pre_build.sh")
  hook_deliver_raw = templatefile("${path.module}/templates/factory/deliver.sh.tftpl", {
    image_base    = local.image_base_placeholder
    container_url = local.container_url
    write_sas     = local.sas_placeholder
  })
  hook_on_exit = "rm -f \"$${VHD:-/nonexistent}\" \"$${VHD:-/nonexistent}.done\" \"$${VHD:-/nonexistent}\".chunk*"
}

locals {
  # A local so the size precondition can read it.
  jumphost_user_data = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    config_bundle  = module.config.config_bundle
    factory_script = local.factory_script
    config_dir     = local.config_dir
    build          = local.build_image
  })

  # cloud-init reads gzip data; custom_data is base64 text of at most 87380 characters.
  jumphost_custom_data = base64gzip(local.jumphost_user_data)
  custom_data_budget   = 87380
}

# A new build replaces the jumphost: cloud-init runs the script on first boot only.
# Always present (replace_triggered_by needs an instance); image_id pins a constant.
resource "terraform_data" "build_trigger" {
  input = local.build_image ? module.config.build_hash : "image_id"
}

resource "azurerm_public_ip" "jumphost" {
  count = local.jumphost_enabled ? 1 : 0

  depends_on = [terraform_data.limits_check]

  name                = "${var.cluster_name}-jumphost"
  location            = local.region
  resource_group_name = local.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = null
  tags                = merge(local.labels, { "elemental-role" = "jumphost" })

  lifecycle {
    ignore_changes = [zones]
  }
}

resource "azurerm_network_interface" "jumphost" {
  count = local.jumphost_enabled ? 1 : 0

  name                = "${var.cluster_name}-jumphost"
  location            = local.region
  resource_group_name = local.resource_group_name
  tags                = merge(local.labels, { "elemental-role" = "jumphost" })

  ip_configuration {
    name                          = "internal"
    subnet_id                     = local.public_subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.jumphost[0].id
  }
}

resource "azurerm_network_interface_security_group_association" "jumphost" {
  count = local.jumphost_enabled ? 1 : 0

  network_interface_id      = azurerm_network_interface.jumphost[0].id
  network_security_group_id = azurerm_network_security_group.this["jumphost"].id
}

resource "azurerm_linux_virtual_machine" "jumphost" {
  count = local.jumphost_enabled ? 1 : 0

  depends_on = [terraform_data.limits_check]

  name                  = "${var.cluster_name}-jumphost"
  location              = local.region
  resource_group_name   = local.resource_group_name
  size                  = local.jumphost_type
  network_interface_ids = [azurerm_network_interface.jumphost[0].id]
  custom_data           = local.jumphost_custom_data
  tags                  = merge(local.labels, { "elemental-role" = "jumphost" })

  admin_username                  = local.jumphost_admin_user
  disable_password_authentication = true

  dynamic "admin_ssh_key" {
    for_each = toset(var.ssh_authorized_keys)

    content {
      username   = local.jumphost_admin_user
      public_key = admin_ssh_key.value
    }
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = local.os_disk_type
    disk_size_gb         = local.jumphost_disk_gb
  }

  source_image_reference {
    publisher = local.jumphost_image_ref["publisher"]
    offer     = local.jumphost_image_ref["offer"]
    sku       = local.jumphost_image_ref["sku"]
    version   = local.jumphost_image_ref["version"]
  }

  boot_diagnostics {}

  lifecycle {
    # The write SAS in custom_data must never replan the jumphost; a new build
    # replaces it through build_trigger.
    ignore_changes       = [custom_data]
    replace_triggered_by = [terraform_data.build_trigger]

    precondition {
      condition     = local.jumphost_image_ref != null
      error_message = "jumphost_image must be a marketplace URN publisher:offer:sku:version."
    }

    precondition {
      # nonsensitive() on the length only, so the error can show the size.
      condition     = nonsensitive(length(local.jumphost_custom_data)) < local.custom_data_budget
      error_message = "Jumphost custom_data is ${nonsensitive(length(local.jumphost_custom_data))} characters, over the budget of ${local.custom_data_budget} (Azure allows 64 KB)."
    }
  }
}

locals {
  jumphost_access = {
    public_ip  = one(azurerm_public_ip.jumphost[*].ip_address)
    private_ip = one(azurerm_network_interface.jumphost[*].private_ip_address)
    ssh_user   = local.jumphost_admin_user
  }

  build_status_value = {
    method     = "page-blob"
    url_or_key = "${local.storage_account_name}/${local.container_name}/${local.vhd_name}"
    hosts      = compact([local.jumphost_access.private_ip])
  }
}

# Jumphost and build host in state for scripts/lib/ssh.sh during the apply;
# outputs reach the state file only after the image exists.
resource "terraform_data" "build_access" {
  count = local.build_image ? 1 : 0

  input = {
    build_id     = module.config.build_id
    jumphost     = local.jumphost_access
    build_status = local.build_status_value
  }
}

# Blocks the apply until the jumphost has uploaded the VHD and the marker
# (90 minutes at most). Replaced on every new build so a rebuild waits again.
resource "terraform_data" "image_ready" {
  count = local.build_image ? 1 : 0

  depends_on = [azurerm_linux_virtual_machine.jumphost]

  triggers_replace = [local.image_base]

  provisioner "local-exec" {
    command = "${path.module}/scripts/wait-for-image.sh"
    environment = {
      DONE_URL        = local.done_url
      TIMEOUT_SECONDS = local.image_build_timeout
      POLL_SECONDS    = 30
    }
  }
}
