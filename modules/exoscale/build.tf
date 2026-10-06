# Unguessable path the image is served from. Rotated per build_hash: it lands
# in the factory script and replaces the jumphost and the template.
resource "random_id" "serve_path" {
  byte_length = 16

  keepers = {
    build = module.config.build_hash
  }
}

# Builds the raw with podman, converts it to qcow2 and serves it over HTTP
# (import in image.tf): the shared image-factory script plus the hooks in
# templates/factory/. Hook placeholders are substituted in local.factory_script.
module "image_factory" {
  source = "../image-factory"

  elemental_image = var.elemental_image
  build_id        = local.build_id_placeholder
  config_dir      = local.config_dir
  log_file        = "/var/log/elemental-factory.log"
  extra_packages  = ["python3"]

  hook_pre_build = templatefile("${path.module}/templates/factory/pre_build.sh.tftpl", {
    serve_path = local.serve_path_placeholder
  })
  hook_deliver_raw = templatefile("${path.module}/templates/factory/deliver.sh.tftpl", {
    serve_path       = local.serve_path_placeholder
    image_base       = local.image_base_placeholder
    serve_seconds    = local.image_serve_seconds
    template_min_gib = local.template_min_gib
  })
  hook_on_exit = templatefile("${path.module}/templates/factory/on_exit.sh.tftpl", {
    image_base = local.image_base_placeholder
  })
}

locals {
  # A local so the size precondition can read it.
  jumphost_user_data = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    files               = module.config.elemental_files
    factory_script      = local.factory_script
    config_dir          = local.config_dir
    ssh_authorized_keys = var.ssh_authorized_keys
    jumphost_username   = var.jumphost_username
  })
}

# jumphost_image is a public template name, or a template ID used as is
# (public template IDs change when Exoscale updates the template).
data "exoscale_template" "jumphost" {
  count = local.jumphost_template_is_id ? 0 : 1

  zone = local.zone
  name = local.jumphost_template
}

locals {
  jumphost_template_is_id = can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", local.jumphost_template))
  jumphost_template_id    = local.jumphost_template_is_id ? local.jumphost_template : one(data.exoscale_template.jumphost[*].id)
}

# openSUSE Leap jumphost (not the template it builds): builds and serves the
# image, then stays as the only SSH entry. Static lease below the DHCP range.
resource "exoscale_compute_instance" "jumphost" {
  depends_on = [terraform_data.api_check]

  zone        = local.zone
  name        = "${var.cluster_name}-jumphost"
  template_id = local.jumphost_template_id
  type        = local.jumphost_type
  disk_size   = local.jumphost_disk_gb

  security_group_ids = [exoscale_security_group.jumphost.id]
  labels             = merge(local.labels, { "elemental-role" = "jumphost" })

  network_interface {
    network_id = exoscale_private_network.this.id
    ip_address = local.jumphost_private_ip
  }

  user_data = local.jumphost_user_data

  lifecycle {
    # user_data updates in place and cloud-init would not run again: a new
    # build (new serve path) replaces the jumphost instead.
    replace_triggered_by = [random_id.serve_path]

    precondition {
      # The API takes at most 32768 base64 characters. nonsensitive() on the
      # length only, so the error can show the size.
      condition     = length(base64encode(local.jumphost_user_data)) < 32768
      error_message = "Rendered jumphost user_data is ${nonsensitive(length(base64encode(local.jumphost_user_data)))} characters in base64, over the 32768 limit. Look for a template rendering something twice, unusually large ssh_authorized_keys (RSA keys run 700+ bytes each; ed25519 keys are ~80), or oversized credential values."
    }
  }
}
