# Build host = build host only: builds the raw image with podman, writes it with dd
# to a blank volume attached as a second disk and publishes the build state over
# HTTP (templates/factory/on-step.sh.tftpl); the node image is exported from that
# volume (image.tf). Then it powers off (buildhost_power_off). No bastion: nodes
# are reached directly on the VM network. With image_id set it does not exist.

locals {
  build_image       = var.image_id == null
  buildhost_enabled = local.build_image

  # Download the buildhost image unless an existing one is named.
  buildhost_download = local.buildhost_enabled && var.jumphost_image == null
}

# A new build replaces the buildhost and the volume: cloud-init runs the script
# on first boot only, and a volume can be attached to one VM at a time.
# Always present (replace_triggered_by needs an instance); image_id pins a constant.
resource "terraform_data" "build_trigger" {
  input = local.build_image ? module.config.build_hash : "image_id"
}

resource "harvester_image" "buildhost" {
  count = local.buildhost_download ? 1 : 0

  depends_on = [terraform_data.input_checks]

  name               = "${var.cluster_name}-buildhost"
  namespace          = var.harvester_namespace
  display_name       = "${var.cluster_name}-buildhost"
  source_type        = "download"
  url                = var.buildhost_image_url
  storage_class_name = local.buildhost_class
  labels             = merge(local.labels, { "elemental-role" = "image" })

  # The provider default (5 minutes) can be shorter than the download and import.
  timeouts {
    create = "30m"
  }
}

locals {
  buildhost_image_ref = var.jumphost_image != null ? var.jumphost_image : one(harvester_image.buildhost[*].id)

  image_base = "${var.cluster_name}-${module.config.build_id}"

  # build_id is part of the volume and image names, so the placeholder keeps the shared script's hash static.
  build_id_placeholder = "@@BUILD_ID@@"

  factory_script = replace(module.image_factory.script_stripped, local.build_id_placeholder, module.config.build_id)
}

# The raw image lands here; the node image is exported from it.
resource "harvester_volume" "image_target" {
  count = local.build_image ? 1 : 0

  depends_on = [terraform_data.input_checks]

  name               = "${var.cluster_name}-image-${module.config.build_id}"
  namespace          = var.harvester_namespace
  size               = "${local.image_disk_gib}Gi"
  storage_class_name = var.storage_class_name
  volume_mode        = "Block"
  access_mode        = local.target_access_mode
  labels = merge(local.labels, {
    "elemental-role"  = "image"
    "elemental-build" = module.config.build_id
  })
}

# Builds the raw with podman and writes it to the target disk (templates/factory/):
# the shared image-factory script plus provider hooks. Leap installs podman with zypper.
module "image_factory" {
  source = "../image-factory"

  elemental_image = var.elemental_image
  build_id        = local.build_id_placeholder
  config_dir      = local.config_dir
  log_file        = "/var/log/elemental-factory.log"
  package_manager = "zypper"

  hook_on_step = templatefile("${path.module}/templates/factory/on-step.sh.tftpl", {
    status_dir = local.status_dir
  })
  hook_deliver_raw = templatefile("${path.module}/templates/factory/deliver.sh.tftpl", {})
  hook_on_exit = templatefile("${path.module}/templates/factory/on_exit.sh.tftpl", {
    power_off = var.buildhost_power_off
  })
}

locals {
  # A local so the size precondition can read it.
  buildhost_user_data = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    config_bundle       = module.config.config_bundle
    factory_script      = local.factory_script
    config_dir          = local.config_dir
    ssh_authorized_keys = var.ssh_authorized_keys
    jumphost_username   = var.jumphost_username
    build               = local.build_image
    status_dir          = local.status_dir
    status_port         = local.status_port
  })

  # Secret limit is 1 MiB; user_data_max_bytes is the same budget as the nodes'.
  user_data_budget = 900000
}

resource "harvester_cloudinit_secret" "buildhost" {
  count = local.buildhost_enabled ? 1 : 0

  depends_on = [terraform_data.input_checks]

  name      = "${var.cluster_name}-buildhost"
  namespace = var.harvester_namespace
  user_data = local.buildhost_user_data
  labels    = merge(local.labels, { "elemental-role" = "builder" })

  lifecycle {
    replace_triggered_by = [terraform_data.build_trigger]

    precondition {
      condition     = length(local.buildhost_user_data) < local.user_data_budget
      error_message = "Build host user_data is ${nonsensitive(length(local.buildhost_user_data))} bytes, over the budget of ${local.user_data_budget} (Secrets are limited to 1 MiB). Look for unusually large ssh_authorized_keys or credential values."
    }
  }
}

resource "harvester_virtualmachine" "buildhost" {
  count = local.buildhost_enabled ? 1 : 0

  depends_on = [terraform_data.input_checks]

  name         = "${var.cluster_name}-buildhost"
  namespace    = var.harvester_namespace
  hostname     = "${var.cluster_name}-buildhost"
  description  = "Image build host of ${var.cluster_name}"
  labels       = merge(local.labels, { "elemental-role" = "builder" })
  cpu          = local.buildhost_size.cpu
  memory       = "${local.buildhost_size.memory}Gi"
  efi          = true
  secure_boot  = false
  machine_type = "q35"

  network_interface {
    name           = "nic-1"
    network_name   = var.vpc_id
    mac_address    = local.macs["${var.cluster_name}-buildhost"]
    wait_for_lease = true
  }

  disk {
    name        = "rootdisk"
    type        = "disk"
    bus         = "virtio"
    boot_order  = 1
    size        = "${local.buildhost_disk_gb}Gi"
    image       = local.buildhost_image_ref
    auto_delete = true
    access_mode = local.buildhost_access_mode
  }

  dynamic "disk" {
    for_each = harvester_volume.image_target

    content {
      name                 = "image-target"
      type                 = "disk"
      bus                  = "virtio"
      existing_volume_name = disk.value.name
    }
  }

  cloudinit {
    type                  = "noCloud"
    user_data_secret_name = harvester_cloudinit_secret.buildhost[0].name
  }

  timeouts {
    create = "30m"
  }

  lifecycle {
    replace_triggered_by = [terraform_data.build_trigger]

    precondition {
      condition     = local.buildhost_image_ref != null
      error_message = "No buildhost image: set jumphost_image or buildhost_image_url."
    }
  }
}

locals {
  # The VLAN address is both: there is no public/private split. A powered-off
  # buildhost reports an empty address: null then.
  buildhost_ip = try(coalesce(one(harvester_virtualmachine.buildhost[*].network_interface[0].ip_address)), null)

  buildhost_access = {
    public_ip  = local.buildhost_ip
    private_ip = local.buildhost_ip
    ssh_user   = var.jumphost_username != "" ? var.jumphost_username : "root"
  }

  status_url = local.buildhost_ip == null ? null : "http://${local.buildhost_ip}:${local.status_port}/status"

  build_status_value = {
    method     = "http-status"
    url_or_key = local.status_url
    hosts      = compact([local.buildhost_ip])
  }
}

# Build host and build host in state for scripts/lib/ssh.sh during the apply;
# outputs reach the state file only after the image exists. Keeps the build-time
# address after the buildhost powers off (ignore_changes; replaced per build).
resource "terraform_data" "build_access" {
  count = local.build_image ? 1 : 0

  triggers_replace = [module.config.build_id]

  input = {
    build_id     = module.config.build_id
    buildhost    = local.buildhost_access
    build_status = local.build_status_value
  }

  lifecycle {
    ignore_changes = [input]
  }
}

# Blocks the apply until the buildhost reports done for this build (90 minutes at
# most), then until it is off (POWER_OFF), so the export reads a detached volume.
# Replaced on every new build so a rebuild waits again.
resource "terraform_data" "image_ready" {
  count = local.build_image ? 1 : 0

  depends_on = [harvester_virtualmachine.buildhost]

  triggers_replace = [module.config.build_id]

  provisioner "local-exec" {
    command = "${path.module}/scripts/wait-for-image.sh"
    environment = {
      STATUS_URL      = local.status_url
      BUILD_ID        = module.config.build_id
      TIMEOUT_SECONDS = local.image_build_timeout
      POLL_SECONDS    = 20
      POWER_OFF       = var.buildhost_power_off
    }
  }
}
