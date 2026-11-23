# Jumphost and build host: builds the raw image and writes it onto a blank
# persistent disk attached to it, then reports through guest attributes. It
# holds no service account and no object storage access. It stays as the SSH
# bastion into the private nodes: with image_id set it exists only while nodes
# are deployed and builds nothing. The snapshot and image are in image.tf.

locals {
  build_image = var.image_id == null
  # The nodes are private: the jumphost is their only SSH entry.
  jumphost_enabled = local.build_image || var.deploy_nodes

  jumphost_name = "${var.cluster_name}-jumphost"
  # Guest attribute namespace the build writes to (build_id, state, message).
  attribute_namespace = "aif"
  target_device_name  = "image-target"

  # The build id is a placeholder in the shared script, so its script_hash (a
  # build_hash input) is static. The stripped script ships in the startup script.
  build_id_placeholder = "@@BUILD_ID@@"

  factory_script = replace(module.image_factory.script_stripped, local.build_id_placeholder, module.config.build_id)
}

# Builds the raw with podman and writes it onto the target disk (templates/factory/):
# the shared image-factory script plus provider hooks. The public Leap image
# ships curl; zypper installs podman.
module "image_factory" {
  source = "../image-factory"

  elemental_image = var.elemental_image
  build_id        = local.build_id_placeholder
  config_dir      = local.config_dir
  log_file        = "/var/log/elemental-factory.log"
  package_manager = "zypper"

  hook_on_step = templatefile("${path.module}/templates/factory/on-step.sh.tftpl", {
    namespace = local.attribute_namespace
  })
  hook_deliver_raw = templatefile("${path.module}/templates/factory/deliver.sh.tftpl", {
    device_name = local.target_device_name
  })
}

# The blank disk the raw image is written onto. The name carries the build id,
# so a new build gets a new disk and never shows an older image through.
resource "google_compute_disk" "image_target" {
  count = local.build_image ? 1 : 0

  depends_on = [terraform_data.limits_check]

  name   = "${var.cluster_name}-image-${module.config.build_id}"
  zone   = local.zones[0]
  type   = "pd-balanced"
  size   = local.image_target_gb
  labels = merge(local.labels, { "elemental-role" = "image", "elemental-build" = module.config.build_id })
}

locals {
  # A local so the size precondition can read it.
  jumphost_startup_script = templatefile("${path.module}/templates/startup-script.sh.tftpl", {
    config_bundle     = module.config.config_bundle
    factory_script    = base64gzip(local.factory_script)
    config_dir        = local.config_dir
    ssh_keys          = var.ssh_authorized_keys
    jumphost_username = var.jumphost_username
    build             = local.build_image
  })

  # The guest agent creates the login user from this metadata (no sudo password).
  jumphost_ssh_keys = join("\n", [for k in var.ssh_authorized_keys : "${var.jumphost_username}:${k}"])

  # One metadata value is limited to 256 KiB (262144 bytes).
  metadata_value_max = 262144 - 12288
}

# A new build replaces the jumphost: the startup script builds on first boot only.
# Always present (replace_triggered_by needs an instance); image_id pins a constant.
resource "terraform_data" "build_trigger" {
  input = local.build_image ? module.config.build_hash : "image_id"
}

resource "google_compute_instance" "jumphost" {
  count = local.jumphost_enabled ? 1 : 0

  depends_on = [terraform_data.limits_check]

  name         = local.jumphost_name
  zone         = local.zones[0]
  machine_type = local.jumphost_type
  tags         = [local.tags["jumphost"]]
  labels       = merge(local.labels, { "elemental-role" = "jumphost" })

  boot_disk {
    interface = local.boot_disk_interface[local.jumphost_type]

    initialize_params {
      image  = local.jumphost_image
      size   = local.jumphost_disk_gb
      type   = local.boot_disk_type[local.jumphost_type]
      labels = merge(local.labels, { "elemental-role" = "jumphost" })
    }
  }

  dynamic "attached_disk" {
    for_each = google_compute_disk.image_target

    content {
      source      = attached_disk.value.self_link
      device_name = local.target_device_name
      mode        = "READ_WRITE"
    }
  }

  network_interface {
    subnetwork = local.subnetwork_id
    # gVNIC only where the family requires it: the public Leap image may not declare it.
    nic_type = contains(local.nvme_families, local.machine_family[local.jumphost_type]) ? "GVNIC" : null

    # Ephemeral public address: the jumphost is the only SSH entry.
    access_config {}
  }

  metadata = merge(
    {
      startup-script          = local.jumphost_startup_script
      enable-guest-attributes = "TRUE"
      enable-oslogin          = "FALSE"
      block-project-ssh-keys  = "TRUE"
    },
    var.jumphost_username == "" ? {} : { ssh-keys = local.jumphost_ssh_keys },
  )

  lifecycle {
    # The startup script runs the build; a newer Leap image must not replan the
    # jumphost. A new build replaces it through build_trigger.
    ignore_changes       = [metadata, boot_disk[0].initialize_params[0].image]
    replace_triggered_by = [terraform_data.build_trigger]

    precondition {
      # nonsensitive() on the length only, so the error can show the size.
      condition     = length(local.jumphost_startup_script) <= local.metadata_value_max
      error_message = "The jumphost startup script is ${nonsensitive(length(local.jumphost_startup_script))} characters, over the budget of ${local.metadata_value_max} (a metadata value holds 262144 bytes). Look for unusually large ssh_authorized_keys (RSA keys run 700+ bytes each; ed25519 keys are ~80), or oversized credential values."
    }
  }
}

locals {
  jumphost_access = {
    public_ip  = one(google_compute_instance.jumphost[*].network_interface[0].access_config[0].nat_ip)
    private_ip = one(google_compute_instance.jumphost[*].network_interface[0].network_ip)
    ssh_user   = var.jumphost_username != "" ? var.jumphost_username : "root"
  }

  build_status_value = {
    method     = "guest-attributes"
    url_or_key = "projects/${var.gcp_project}/zones/${local.zones[0]}/instances/${local.jumphost_name}"
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

# Blocks the apply until the jumphost reports the current build written to the
# target disk, the build fails, or the timeout expires (90 minutes). Replaced on
# every new build so a rebuild waits again. The access token comes from the
# provider's credentials; the script never prints it.
resource "terraform_data" "image_ready" {
  count = local.build_image ? 1 : 0

  depends_on = [google_compute_instance.jumphost]

  triggers_replace = [module.config.build_id]

  provisioner "local-exec" {
    command = "${path.module}/scripts/wait-for-image.sh"
    environment = {
      PROJECT      = var.gcp_project
      ZONE         = local.zones[0]
      INSTANCE     = local.jumphost_name
      NAMESPACE    = local.attribute_namespace
      BUILD_ID     = module.config.build_id
      ACCESS_TOKEN = nonsensitive(data.google_client_config.this.access_token)

      TIMEOUT_SECONDS = local.image_build_timeout
      POLL_SECONDS    = 30
    }
  }
}
