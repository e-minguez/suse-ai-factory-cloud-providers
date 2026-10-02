# Everything baked into the image (release.yaml, butane.yaml, RKE2 config, Helm
# values) and every node's Ignition user_data come from the shared module.
# build_hash is the only rebuild trigger (image.tf, build.tf).
module "config" {
  source = "../elemental-config"

  cluster_name = var.cluster_name
  api_vip      = local.api_vip
  api_host     = local.api_host
  api_vip_mode = local.api_vip_mode
  vpc_cidr     = local.vpc_cidr
  tls_san      = []
  rke2_token   = random_password.token.result

  nodes = [
    for n in local.cluster_nodes : {
      hostname = n.hostname
      type     = n.type
      role     = n.role
      init     = n.init
      pool     = n.pool
    }
  ]

  user_data_max_bytes = 32768
  kernel_cmdline      = "console=ttyS1,115200n8 console=tty0 quiet ignition.platform.id=vultr"

  canal_iface_regex  = local.vpc_iface_regex
  pod_veth_mtu       = local.pod_veth_mtu
  ingress_controller = var.ingress_controller
  components         = var.components
  suse_storage_nodes = var.suse_storage_nodes

  elemental_image = var.elemental_image
  image_disk_size = var.image_disk_size
  fips            = var.fips

  root_password_hash      = var.root_password_hash
  node_user_password_hash = var.node_user_password_hash
  ssh_authorized_keys     = var.ssh_authorized_keys
  node_username           = var.node_username
  permit_root_ssh         = var.permit_root_ssh

  aif_release            = var.aif_release
  core_platform_override = var.core_platform_override
  sysext_image_overrides = var.sysext_image_overrides

  appco_username         = var.appco_username
  appco_password         = var.appco_password
  appco_registry         = var.appco_registry
  suse_registry_username = var.suse_registry_username
  suse_registry_password = var.suse_registry_password
  nvidia_api_key         = var.nvidia_api_key
  nvidia_username        = var.nvidia_username
  gpu_driver_repository  = var.gpu_driver_repository
  gpu_driver_version     = var.gpu_driver_version

  rancher_hostname           = local.rancher_hostname
  rancher_bootstrap_password = var.rancher_bootstrap_password

  enable_write_node_ip = true

  extra_config_files = {
    "network/configure-network.sh" = templatefile("${path.module}/templates/elemental/network/configure-network.sh.tftpl", {
      nat_gateway_ip = vultr_nat_gateway.this.private_ips[0]
      vpc_mtu        = local.vpc_mtu
      vpc_prefix     = local.vpc_prefix
      dns_servers    = local.dns_servers
    })
  }

  # The factory script is provider-owned and not in the config dir.
  image_rebuild = var.image_rebuild

  extra_build_inputs = {
    factory = module.image_factory.script_hash
  }
}

# Warns rather than fails: some pre-release tags ship a manifest whose
# metadata.version differs from the tag. Skipped for a manifest URL.
check "aif_release_matches_manifest" {
  assert {
    condition = (
      can(regex("^https?://", var.aif_release)) ||
      try(yamldecode(module.config.release_manifest).metadata.version, "") == var.aif_release
    )
    error_message = "aif_release is \"${var.aif_release}\", but the manifest at tag aif-operator-${var.aif_release} declares metadata.version ${try(yamldecode(module.config.release_manifest).metadata.version, "(unreadable)")}, and that is what will be built."
  }
}

# The jumphost builds and serves the raw image; vultr_snapshot_from_url imports
# it, so `terraform destroy` removes the snapshot. Order: jumphost build,
# terraform_data.image_served (poll), snapshot import, nodes. A new build_hash
# rotates random_id.serve_path (build.tf), replacing jumphost and snapshot.

locals {
  # image_name is also the snapshot description; image_file e.g. "suse-ai-factory-1a2b3c4d5e6f.raw".
  image_name = "${var.cluster_name}-${module.config.build_id}"
  image_file = "${local.image_name}.raw"
  image_url  = "http://${vultr_instance.jumphost.main_ip}/${random_id.serve_path.hex}/${local.image_file}"
}

# Jumphost and build host in state for scripts/lib/ssh.sh during the apply;
# outputs reach the state file only after the snapshot exists.
resource "terraform_data" "build_access" {
  count = var.image_id == null ? 1 : 0

  input = {
    build_id     = module.config.build_id
    jumphost     = local.jumphost_access
    build_status = local.build_status_value
  }
}

# Port 80 for the create-from-url fetcher. A resource, so it cannot be created
# and removed in one apply: deploy.sh pass 2 sets image_import_port_open = false,
# pass 1 resets it when the snapshot is created. Created with the jumphost so the
# rule has propagated by the time the build ends.
resource "vultr_firewall_rule" "image_import" {
  count = var.image_import_port_open ? 1 : 0

  firewall_group_id = vultr_firewall_group.jumphost.id
  protocol          = "tcp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  port              = "80"
  notes             = "elemental image import"
}

# Waits until the raw is served, or image_build_timeout runs out. Polled from
# the operator machine over the public path the fetcher uses.
# triggers_replace keys off the build, not the URL, so a replaced jumphost does
# not trigger a new import.
resource "terraform_data" "image_served" {
  count = var.image_id == null ? 1 : 0

  depends_on = [vultr_firewall_rule.image_import]

  triggers_replace = [random_id.serve_path.hex]
  input            = local.image_url

  provisioner "local-exec" {
    command = "${path.module}/scripts/wait-for-image.sh"
    environment = {
      IMAGE_URL       = local.image_url
      TIMEOUT_SECONDS = local.image_build_timeout
      POLL_SECONDS    = 30
    }
  }
}

# One attempt: when the fetch fails Vultr deletes the record, so recovery needs
# a `terraform state rm` (module README, Known gaps). url embeds the jumphost IP
# and is ForceNew, hence ignore_changes; a new build replaces it through
# replace_triggered_by.
resource "vultr_snapshot_from_url" "ai_factory" {
  count = var.image_id == null ? 1 : 0

  depends_on = [terraform_data.image_served]

  url      = local.image_url
  use_uefi = true

  lifecycle {
    ignore_changes       = [url]
    replace_triggered_by = [random_id.serve_path]
  }

  # The provider returns while the status is "pending"; this waits for
  # "complete", and a failure taints the resource. It then sets the description
  # (computed-only in the provider) so leftovers can find the snapshot by name.
  provisioner "local-exec" {
    command = "${path.module}/scripts/wait-for-snapshot.sh"
    environment = {
      SNAPSHOT_ID          = self.id
      SNAPSHOT_DESCRIPTION = local.image_name
      TIMEOUT_SECONDS      = local.image_serve_seconds
      POLL_SECONDS         = 30
      VULTR_API_KEY        = var.vultr_api_key
    }
  }
}

locals {
  # one(): the build resource has count = 0 when image_id is set.
  effective_snapshot_id = var.image_id != null ? var.image_id : one(vultr_snapshot_from_url.ai_factory[*].id)
}
