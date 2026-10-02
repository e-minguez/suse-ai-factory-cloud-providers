# Pass 2 of the two-pass image build: once var.image_ready is true the
# hotswap attachments are gone and image_target disks hold finished images.
# One snapshot per zone, because snapshots are zonal (build.tf).

# One build id for all zones (same inputs), from the config module's build_hash;
# the zone appears only in the snapshot name.
locals {
  build_id = module.config.build_id

  # "/compute/projects/<project>/regions/<region>/disks/", read off a sibling disk
  # because var.project defaults to null and the provider supplies it.
  disk_fqid_prefix = trimsuffix(
    evroc_disk.jumphost_boot[local.primary_zone].fqid,
    evroc_disk.jumphost_boot[local.primary_zone].name,
  )

  snapshot_names = {
    for z in local.zones : z => "${var.cluster_name}-${local.build_id}-snapshot-${z}"
  }
}

# Only when image_ready is true, after the hotswap attachment is destroyed; if
# the platform still sees the disk attached, re-run the apply. The builders are
# listed to order their teardown (vCPU quota) before nodes. No user_labels
# attribute exists. See docs/decisions/004-evroc-module-rationale.md.
resource "evroc_snapshot" "ai_factory" {
  for_each = length(var.image_ids) == 0 && var.image_ready ? toset(local.zones) : toset([])

  depends_on = [
    evroc_hotswap_disk_attachment.image_target,
    evroc_virtual_machine.builder,
  ]

  # try(): image_target has no instances once keep_build_artifacts reclaims them.
  # The fallback must equal the real fqid (immutable field); the disk reference
  # inside try() keeps the disk-before-snapshot edge.
  disk_ref = try(evroc_disk.image_target[each.key].fqid, "${local.disk_fqid_prefix}${local.image_target_disk_names[each.key]}")
  name     = local.snapshot_names[each.key]
  project  = var.project
  region   = var.region

  lifecycle {
    # A disk_ref mismatch would delete the snapshot node disks were cloned from.
    ignore_changes = [disk_ref]
  }
}

locals {
  # Zone -> snapshot a node in that zone clones from (zonal). Conditional, not
  # coalesce(): coalesce() errors when both branches are null. Values are unknown
  # at plan time; keys are plan-known.
  effective_snapshot_ids = {
    for z in local.zones : z => (
      length(var.image_ids) > 0
      ? var.image_ids[z]
      : try(evroc_snapshot.ai_factory[z].fqid, null)
    )
  }

  # Will a snapshot exist after this apply, from plan-known variables only. Gating
  # nodes on snapshot ids makes the for_each keys unknown and breaks plan and
  # destroy (docs/decisions/004-evroc-module-rationale.md).
  snapshot_expected = length(var.image_ids) > 0 || var.image_ready
}

# Elemental config dir, release manifest and per-node Ignition, rendered by
# the shared module. Build identity comes from its build_hash.
module "config" {
  source = "../elemental-config"

  cluster_name = var.cluster_name
  api_vip      = local.api_vip
  api_host     = local.api_host
  api_vip_mode = local.api_vip_mode
  tls_san      = []
  vpc_cidr     = local.vpc_cidr
  rke2_token   = random_password.token.result

  canal_iface_regex  = local.vpc_iface_regex
  pod_veth_mtu       = local.pod_veth_mtu
  ingress_controller = var.ingress_controller

  nodes = [
    for n in local.cluster_nodes : {
      hostname = n.hostname
      type     = n.type
      init     = try(n.init, false) == true
      role     = n.role
      pool     = n.pool
    }
  ]

  # evroc allows 1 MB of user_data; 768 KiB leaves room for base64 expansion.
  user_data_max_bytes = 786432
  kernel_cmdline      = "console=ttyS0 console=tty0 ignition.platform.id=proxmoxve"

  root_password_hash      = var.root_password_hash
  node_user_password_hash = var.node_user_password_hash
  ssh_authorized_keys     = var.ssh_authorized_keys
  node_username           = var.node_username
  permit_root_ssh         = var.permit_root_ssh

  elemental_image    = var.elemental_image
  image_disk_size    = var.image_disk_size
  fips               = var.fips
  components         = var.components
  suse_storage_nodes = var.suse_storage_nodes

  aif_release            = var.aif_release
  core_platform_override = var.core_platform_override
  sysext_image_overrides = var.sysext_image_overrides

  appco_username             = var.appco_username
  appco_password             = var.appco_password
  appco_registry             = var.appco_registry
  suse_registry_username     = var.suse_registry_username
  suse_registry_password     = var.suse_registry_password
  nvidia_api_key             = var.nvidia_api_key
  nvidia_username            = var.nvidia_username
  gpu_driver_repository      = var.gpu_driver_repository
  gpu_driver_version         = var.gpu_driver_version
  rancher_hostname           = local.rancher_hostname
  rancher_bootstrap_password = var.rancher_bootstrap_password

  enable_write_node_ip = true

  extra_config_files = {
    "network/configure-network.sh" = templatefile("${path.module}/templates/elemental/network/configure-network.sh.tftpl", {
      vpc_mtu = local.vpc_mtu
      # One prefix length for every zone's subnet (cidrsubnet, one newbits).
      vpc_prefix = local.subnet_prefix
    })
  }

  # The factory script is owned by this module and is not in the config dir.
  image_rebuild = var.image_rebuild

  extra_build_inputs = {
    factory = module.image_factory.script_hash
  }
}

# One zone-independent build-host script; locals.tf substitutes the zone and
# build id placeholders. Hooks: relay status (on_step) and dd the raw image onto
# the attached disk (deliver_raw).
module "image_factory" {
  source = "../image-factory"

  elemental_image = var.elemental_image
  build_id        = local.build_id_placeholder
  config_dir      = local.config_dir
  log_file        = "/var/log/elemental-factory.log"

  hook_on_step = templatefile("${path.module}/templates/factory-on-step.sh.tftpl", {
    zone              = local.zone_placeholder
    status_relay_port = local.status_relay_port
  })
  hook_deliver_raw = file("${path.module}/templates/factory-deliver.sh.tftpl")
}
