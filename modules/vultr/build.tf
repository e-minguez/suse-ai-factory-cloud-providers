# Unguessable path the raw is served from. Rotated per build_hash: it lands in
# the factory script (new build replaces the jumphost) and triggers the snapshot
# replacement.
resource "random_id" "serve_path" {
  byte_length = 16

  keepers = {
    build = module.config.build_hash
  }

  lifecycle {
    # The LB addresses are baked into the image (data.http.lb, loadbalancer.tf).
    precondition {
      condition     = alltrue([for k, d in data.http.lb : d.status_code == 200 && local.lb_ipv4[k] != ""])
      error_message = "Vultr reports no public IPv4 for load balancer(s) ${join(", ", [for k, d in data.http.lb : "${k} (HTTP ${d.status_code})" if d.status_code != 200 || local.lb_ipv4[k] == ""])}. It is baked into the image, so the build cannot proceed without it; re-run the apply once Vultr has assigned one."
    }
  }
}

# Builds the raw with podman and serves it over HTTP (import in image.tf): the
# shared image-factory script plus the hooks in templates/factory/. Hook
# placeholders are substituted in local.factory_script (locals.tf).
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
    serve_path    = local.serve_path_placeholder
    image_file    = local.image_file_placeholder
    serve_seconds = local.image_serve_seconds
  })
  hook_on_exit = templatefile("${path.module}/templates/factory/on_exit.sh.tftpl", {
    image_file = local.image_file_placeholder
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

# openSUSE Leap 16 jumphost (not the elemental snapshot it builds). It needs a
# public IPv4 for admin SSH and for the create-from-url fetcher. user_data
# embeds the load balancer address, which orders it after the load balancers.
resource "vultr_instance" "jumphost" {
  depends_on = [data.http.plan_availability]

  region = var.region
  plan   = local.jumphost_plan
  os_id  = local.jumphost_os_id

  label    = "${var.cluster_name}-jumphost"
  hostname = "${var.cluster_name}-jumphost"

  vpc_ids           = [vultr_vpc.this.id]
  firewall_group_id = vultr_firewall_group.jumphost.id

  ssh_key_ids = var.ssh_key_ids
  tags        = local.jumphost_tags
  enable_ipv6 = local.enable_ipv6

  user_data = local.jumphost_user_data

  lifecycle {
    precondition {
      # 32 KiB is a sanity ceiling, not a documented limit. nonsensitive() on the
      # length only, so the error can show the size.
      condition     = length(local.jumphost_user_data) <= 32768
      error_message = "Rendered jumphost user_data is ${nonsensitive(length(local.jumphost_user_data))} bytes, over the 32 KiB sanity ceiling. Check the comment strip in locals.tf still covers local.factory_script (the module strips the elemental files), then look for a template rendering something twice, unusually large ssh_authorized_keys (RSA keys run 700+ bytes each; ed25519 keys are ~80), or oversized credential values."
    }
  }
}
