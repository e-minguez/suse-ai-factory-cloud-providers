# Pass 1 of the image build (see var.image_ready): build hosts, the blank disks
# they write the raw image onto, and the hotswap attachments; image.tf continues
# from there. One build per zone (snapshots are zonal); jumphost (zones[0]) and
# builder (other zones) are separate resources. See docs/decisions/004-evroc-module-rationale.md.

# Per-zone disks the raw image is written onto, blank at creation. They outlive
# the build hosts; with keep_build_artifacts = false a third apply deletes them.
# !var.image_ready keeps them while a build can still write.
resource "evroc_disk" "image_target" {
  for_each = !var.image_ready || var.keep_build_artifacts ? toset(local.zones) : toset([])

  name = local.image_target_disk_names[each.key]
  # Same zone as the build host: hotswap attachments are zonal.
  zone    = each.key
  size    = var.image_target_disk_gb
  project = var.project
  region  = var.region

  # build_labels: the disk name is stable across rebuilds, the label marks the generation.
  user_labels = merge(local.build_labels, { "elemental-role" = "image" })

  timeouts {
    create = local.disk_create_timeout
    delete = local.disk_delete_timeout
  }
}

# The jumphost's OS disk (local.jumphost_image), in zones[0]. Keyed by zone so
# the state address stays evroc_disk.jumphost_boot["a"].
resource "evroc_disk" "jumphost_boot" {
  for_each = toset([local.primary_zone])

  name    = "${var.cluster_name}-jumphost-boot-${each.key}"
  zone    = each.key
  image   = local.jumphost_image
  size    = local.jumphost_disk_size_gb
  project = var.project
  region  = var.region

  user_labels = merge(local.common_labels, { "elemental-role" = "jumphost" })

  timeouts {
    create = local.disk_create_timeout
    delete = local.disk_delete_timeout
  }
}

# Builder OS disks. Separate from the jumphost's because they are destroyed with
# the builders on pass 2 (builder_zones_active). The build output lives on image_target.
resource "evroc_disk" "builder_boot" {
  for_each = local.builder_zones_active

  name    = "${var.cluster_name}-builder-boot-${each.key}"
  zone    = each.key
  image   = local.jumphost_image
  size    = local.jumphost_disk_size_gb
  project = var.project
  region  = var.region

  user_labels = merge(local.common_labels, { "elemental-role" = "builder" })

  timeouts {
    create = local.disk_create_timeout
    delete = local.disk_delete_timeout
  }
}

# One public IP for the jumphost only; builders use platform egress.
resource "evroc_public_ip" "jumphost" {
  name    = "${var.cluster_name}-jumphost-ip"
  project = var.project
  region  = var.region

  user_labels = merge(local.common_labels, { "elemental-role" = "jumphost" })
}

# Locals so the size preconditions can read them (a precondition cannot reliably
# read its own resource's config). Per zone, because factory_script is per zone.
# The builders' map reads the jumphost's private address, so the two cannot be
# one map (cycle).
locals {
  build_host_user_data_vars = {
    file_names          = module.config.elemental_file_names
    files               = module.config.elemental_files
    config_dir          = local.config_dir
    ssh_authorized_keys = var.ssh_authorized_keys
    jumphost_username   = var.jumphost_username
    status_relay_port   = local.status_relay_port
  }

  jumphost_user_data = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", merge(local.build_host_user_data_vars, {
    factory_script      = local.factory_script[local.primary_zone]
    status_relay_script = file("${path.module}/templates/status-relay.py")
    # Only VPC addresses may publish; 127.0.0.0/8 is the jumphost's own build.
    status_relay_push_cidrs = "${local.vpc_cidr} 127.0.0.0/8"
    status_relay_zones      = join(" ", local.zones)
    status_url              = ""
  }))

  builder_user_data = {
    for z in local.builder_zones : z => templatefile("${path.module}/templates/cloud-init.yaml.tftpl", merge(local.build_host_user_data_vars, {
      factory_script          = local.factory_script[z]
      status_relay_script     = ""
      status_relay_push_cidrs = ""
      status_relay_zones      = ""
      status_url              = "http://${evroc_virtual_machine.jumphost.private_ipv4_address}:${local.status_relay_port}/zones"
    }))
  }

  # Zones whose build host is a builder; plan-known for_each keys.
  builder_zones = toset(slice(local.zones, 1, length(local.zones)))

  # Builders that exist now: none on pass 2 (image.tf orders their teardown before nodes).
  builder_zones_active = var.image_ready ? toset([]) : local.builder_zones
}

# Replaces the builders when the build id changes, so each build gets a fresh factory run.
resource "terraform_data" "build_identity" {
  input = local.build_id
}

# Primary build host and the cluster's bastion, running openSUSE Leap. No UEFI
# label: it boots a stock platform image.
resource "evroc_virtual_machine" "jumphost" {
  # Flavor offered by the platform (availability.tf).
  depends_on = [data.evroc_compute_profiles.this]

  name   = "${var.cluster_name}-jumphost"
  flavor = local.jumphost_instance_type
  # Same zone as its image_target disk (hotswap attachments are zonal).
  zone    = local.primary_zone
  project = var.project
  region  = var.region

  boot_disk       = evroc_disk.jumphost_boot[local.primary_zone].name
  security_groups = [evroc_security_group.jumphost.fqid]
  public_ip       = evroc_public_ip.jumphost.name
  subnet_ref      = evroc_subnet.this[local.primary_zone].fqid
  ssh_keys        = var.ssh_authorized_keys

  cloud_config_user_data = local.jumphost_user_data

  # role jumphost, not build-host: this VM outlives the build as the bastion.
  user_labels = merge(local.common_labels, { "elemental-role" = "jumphost" })

  lifecycle {
    precondition {
      # 32 KiB tripwire, far below the platform's 1 MB, to catch a template
      # rendering the config dir twice. nonsensitive() on the length only.
      condition     = length(local.jumphost_user_data) <= 32768
      error_message = "Rendered jumphost user_data is ${nonsensitive(length(local.jumphost_user_data))} bytes, over the 32 KiB tripwire (evroc's own limit is 1 MB, so this is the module's, not the platform's). Check the comment strip in locals.tf still covers local.factory_script, then look for a template rendering something twice, unusually large ssh_authorized_keys (RSA keys run 700+ bytes each; ed25519 keys are ~80), or oversized credential values."
    }
  }
}

# Build hosts for zones after the first: no public IP, own security group, own
# zone's subnet and disks. Destroyed on pass 2 (builder_zones_active) to free
# vCPU quota; if pass 2 fails partway, recover with --rebuild. The jumphost stays.
resource "evroc_virtual_machine" "builder" {
  # Flavor offered by the platform (availability.tf).
  depends_on = [data.evroc_compute_profiles.this]

  for_each = local.builder_zones_active

  name    = "${var.cluster_name}-builder-${each.key}"
  flavor  = local.jumphost_instance_type
  zone    = each.key
  project = var.project
  region  = var.region

  boot_disk       = evroc_disk.builder_boot[each.key].name
  security_groups = [evroc_security_group.builder[0].fqid]
  subnet_ref      = evroc_subnet.this[each.key].fqid
  ssh_keys        = var.ssh_authorized_keys

  # No public_ip; outbound access is provided by the platform.

  cloud_config_user_data = local.builder_user_data[each.key]
  user_labels            = merge(local.common_labels, { "elemental-role" = "builder" })

  lifecycle {
    replace_triggered_by = [terraform_data.build_identity]

    precondition {
      condition     = length(local.builder_user_data[each.key]) <= 32768
      error_message = "Rendered builder user_data for zone ${each.key} is ${nonsensitive(length(local.builder_user_data[each.key]))} bytes, over the 32 KiB tripwire (evroc's own limit is 1 MB). See the same precondition on evroc_virtual_machine.jumphost for what to check."
    }
  }
}

# Pass 1 (image_ready = false) attaches each image_target disk to its zone's
# build host. Pass 2 empties the for_each; the destroy is the detach that
# precedes snapshotting.
resource "evroc_hotswap_disk_attachment" "image_target" {
  for_each = var.image_ready ? toset([]) : toset(local.zones)

  name = "${var.cluster_name}-image-target-attach-${each.key}"
  disk = evroc_disk.image_target[each.key].name
  # The jumphost owns zones[0]; other zones use builders.
  virtual_machine = each.key == local.primary_zone ? evroc_virtual_machine.jumphost.name : evroc_virtual_machine.builder[each.key].name
  project         = var.project
  region          = var.region

  user_labels = merge(local.common_labels, { "elemental-role" = "image" })
}

# Jumphost and build hosts in state, for scripts/lib/ssh.sh during the apply:
# the outputs reach the state file only after the snapshots exist.
resource "terraform_data" "build_access" {
  count = length(var.image_ids) == 0 ? 1 : 0

  input = {
    build_id     = local.build_id
    jumphost     = local.jumphost_access
    build_status = local.build_status_value
  }
}

# Blocks the apply until every zone reports the current build id written (via
# the status relay), a zone fails, or the timeout expires. Not gated on
# !image_ready, so a stale image fails at once in pass 2. count = 0 when
# image_ids skips the build. See docs/decisions/004-evroc-module-rationale.md.
resource "terraform_data" "image_written" {
  count = length(var.image_ids) == 0 ? 1 : 0

  depends_on = [
    evroc_virtual_machine.jumphost,
    evroc_virtual_machine.builder,
    evroc_hotswap_disk_attachment.image_target,
  ]

  # triggers_replace, not `input`: local-exec runs only on create, and a changed
  # input updates in place.
  triggers_replace = [local.build_id, join(",", local.zones)]

  provisioner "local-exec" {
    command = "${path.module}/scripts/wait-for-image.sh"
    environment = {
      # The relay on the jumphost's public address (plain GETs; firewall.tf opens
      # the port to admin_cidrs while a build can run).
      STATUS_URL = "http://${evroc_public_ip.jumphost.ip_address}:${local.status_relay_port}/zones"
      ZONES      = join(" ", local.zones)

      BUILD_ID        = local.build_id
      TIMEOUT_SECONDS = local.image_build_timeout
      POLL_SECONDS    = 30

      # true only when edited between passes: nothing is building, so fail fast.
      IMAGE_READY = tostring(var.image_ready)
    }
  }
}
