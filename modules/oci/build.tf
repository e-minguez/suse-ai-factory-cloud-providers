# Jumphost and build host: builds the raw image, converts it to qcow2 and
# uploads it to the build bucket through write-only pre-authenticated requests
# (PARs), so it holds no OCI credentials. It stays as the SSH bastion into the
# private nodes: with image_id set it exists only while nodes are deployed and
# builds nothing. The import runs in image.tf.

data "oci_objectstorage_namespace" "this" {
  compartment_id = var.oci_compartment_ocid
}

# Platform image: newest Oracle Linux 9 for the jumphost shape, without the
# aarch64, GPU and minimal variants (their names carry a suffix).
data "oci_core_images" "jumphost" {
  count = local.jumphost_enabled && var.jumphost_image == null ? 1 : 0

  compartment_id           = var.oci_compartment_ocid
  operating_system         = "Oracle Linux"
  operating_system_version = "9"
  shape                    = local.jumphost_shape.name
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
  state                    = "AVAILABLE"

  filter {
    name   = "display_name"
    values = ["^Oracle-Linux-9\\.[0-9]+-[0-9.]+-[0-9]+$"]
    regex  = true
  }
}

# The qcow2 name and the done marker depend on build_hash, so the PARs are
# created per build; the expiry stays fixed for a build (no plan drift).
resource "time_offset" "par_expiry" {
  count = local.build_image ? 1 : 0

  offset_hours = local.par_expiry_hours
  triggers     = { build = module.config.build_hash }
}

resource "oci_objectstorage_bucket" "build" {
  count = local.build_image ? 1 : 0

  compartment_id = var.oci_compartment_ocid
  namespace      = data.oci_objectstorage_namespace.this.namespace
  name           = "${var.cluster_name}-build"
  access_type    = "NoPublicAccess"
  storage_tier   = "Standard"
  freeform_tags  = merge(local.labels, { "elemental-role" = "image" })
}

locals {
  build_image = var.image_id == null
  # The nodes are private: the jumphost is their only SSH entry.
  jumphost_enabled = local.build_image || var.deploy_nodes

  bucket_name   = one(oci_objectstorage_bucket.build[*].name)
  object_host   = "https://objectstorage.${local.region}.oraclecloud.com"
  qcow_key      = "images/${local.image_base}.qcow2"
  done_key      = "images/${local.image_base}.done"
  par_name_base = "${var.cluster_name}-${module.config.build_id}"

  jumphost_image_id = var.jumphost_image != null ? var.jumphost_image : try(data.oci_core_images.jumphost[0].images[0].id, null)

  # Values derived from the build hash are placeholders in the shared script, so
  # its script_hash (a build_hash input) is static. The stripped script ships in user_data.
  build_id_placeholder   = "@@BUILD_ID@@"
  qcow_par_placeholder   = "@@QCOW_PAR_URL@@"
  done_par_placeholder   = "@@DONE_PAR_URL@@"
  image_base_placeholder = "${var.cluster_name}-${local.build_id_placeholder}"

  factory_script = replace(
    replace(
      replace(
        replace(module.image_factory.script_stripped, local.image_base_placeholder, local.image_base),
        local.qcow_par_placeholder, local.build_image ? local.write_par_urls["qcow"] : ""
      ),
      local.done_par_placeholder, local.build_image ? local.write_par_urls["done"] : ""
    ),
    local.build_id_placeholder, module.config.build_id
  )
}

# ObjectWrite allows a PUT of that one object and nothing else. The URLs are
# secrets until the PARs expire.
resource "oci_objectstorage_preauthrequest" "write" {
  for_each = local.build_image ? { qcow = local.qcow_key, done = local.done_key } : {}

  namespace    = data.oci_objectstorage_namespace.this.namespace
  bucket       = local.bucket_name
  name         = "${local.par_name_base}-${each.key}-write"
  access_type  = "ObjectWrite"
  object_name  = each.value
  time_expires = one(time_offset.par_expiry[*].rfc3339)
}

# Terraform polls the done marker through this one.
resource "oci_objectstorage_preauthrequest" "read_done" {
  count = local.build_image ? 1 : 0

  namespace    = data.oci_objectstorage_namespace.this.namespace
  bucket       = local.bucket_name
  name         = "${local.par_name_base}-done-read"
  access_type  = "ObjectRead"
  object_name  = local.done_key
  time_expires = one(time_offset.par_expiry[*].rfc3339)
}

locals {
  write_par_urls = { for k, p in oci_objectstorage_preauthrequest.write : k => sensitive("${local.object_host}${p.access_uri}") }
  read_done_url  = local.build_image ? sensitive("${local.object_host}${oci_objectstorage_preauthrequest.read_done[0].access_uri}") : null
}

# Builds the raw with podman, converts it to qcow2 and uploads it (templates/factory/):
# the shared image-factory script plus provider hooks. Oracle Linux 9 installs
# podman and qemu-img (ol9_appstream) with dnf; the platform image ships curl.
module "image_factory" {
  source = "../image-factory"

  elemental_image = var.elemental_image
  build_id        = local.build_id_placeholder
  config_dir      = local.config_dir
  log_file        = "/var/log/elemental-factory.log"
  package_manager = "dnf"
  extra_packages  = ["qemu-img"]

  hook_deliver_raw = templatefile("${path.module}/templates/factory/deliver.sh.tftpl", {
    image_base = local.image_base_placeholder
    qcow_url   = local.qcow_par_placeholder
    done_url   = local.done_par_placeholder
  })
  hook_on_exit = "rm -f \"$${QCOW:-/nonexistent}\" \"$${QCOW:-/nonexistent}.done\""
}

locals {
  # A local so the size precondition can read it.
  jumphost_user_data = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    config_bundle       = module.config.config_bundle
    factory_script      = local.factory_script
    config_dir          = local.config_dir
    ssh_authorized_keys = var.ssh_authorized_keys
    jumphost_username   = var.jumphost_username
    build               = local.build_image
  })

  # cloud-init reads gzip user_data; the metadata budget counts the base64 text.
  jumphost_user_data_b64   = base64gzip(local.jumphost_user_data)
  jumphost_ssh_keys        = join("\n", var.ssh_authorized_keys)
  jumphost_metadata_budget = 32000 - 1024
}

# A new build replaces the jumphost: cloud-init runs the script on first boot only.
# Always present (replace_triggered_by needs an instance); image_id pins a constant.
resource "terraform_data" "build_trigger" {
  input = local.build_image ? module.config.build_hash : "image_id"
}

resource "oci_core_instance" "jumphost" {
  count = local.jumphost_enabled ? 1 : 0

  depends_on = [terraform_data.limits_check]

  compartment_id      = var.oci_compartment_ocid
  availability_domain = lookup(local.ad_names, local.zones[0], "")
  display_name        = "${var.cluster_name}-jumphost"
  shape               = local.jumphost_shape.name

  dynamic "shape_config" {
    for_each = local.jumphost_shape.flex ? [1] : []

    content {
      ocpus         = local.jumphost_shape.ocpus
      memory_in_gbs = local.jumphost_shape.memory
    }
  }

  source_details {
    source_type             = "image"
    source_id               = local.jumphost_image_id
    boot_volume_size_in_gbs = local.jumphost_disk_gb
  }

  create_vnic_details {
    subnet_id        = local.public_subnet_id
    assign_public_ip = true
    nsg_ids          = [local.nsg_ids["jumphost"]]
    display_name     = "${var.cluster_name}-jumphost"
    freeform_tags    = merge(local.labels, { "elemental-role" = "jumphost" })
  }

  metadata = {
    user_data           = local.jumphost_user_data_b64
    ssh_authorized_keys = local.jumphost_ssh_keys
  }

  preserve_boot_volume = false
  freeform_tags        = merge(local.labels, { "elemental-role" = "jumphost" })

  lifecycle {
    # The write PAR URLs in user_data must never replan the jumphost, nor a newer
    # OL9 image (in-place boot volume swap); a new build replaces it through build_trigger.
    ignore_changes       = [metadata, source_details[0].source_id]
    replace_triggered_by = [terraform_data.build_trigger]

    precondition {
      condition     = local.jumphost_image_id != null
      error_message = "No Oracle Linux 9 platform image found for shape ${local.jumphost_shape.name}. Set jumphost_image to an image OCID."
    }

    precondition {
      # nonsensitive() on the length only, so the error can show the size.
      condition     = length(local.jumphost_user_data_b64) + length(local.jumphost_ssh_keys) < local.jumphost_metadata_budget
      error_message = "Jumphost metadata is ${nonsensitive(length(local.jumphost_user_data_b64) + length(local.jumphost_ssh_keys))} characters, over the budget of ${local.jumphost_metadata_budget} (OCI allows 32000 bytes of metadata). Look for large files in extra_manifests_dir, unusually large ssh_authorized_keys (RSA keys run 700+ bytes each; ed25519 keys are ~80), or oversized credential values."
    }
  }
}

locals {
  jumphost_access = {
    public_ip  = one(oci_core_instance.jumphost[*].public_ip)
    private_ip = one(oci_core_instance.jumphost[*].private_ip)
    ssh_user   = var.jumphost_username != "" ? var.jumphost_username : "root"
  }

  build_status_value = {
    method     = "object-storage"
    url_or_key = "${data.oci_objectstorage_namespace.this.namespace}/${local.bucket_name != null ? local.bucket_name : ""}/${local.qcow_key}"
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

# Blocks the apply until the jumphost has uploaded the qcow2 and the marker
# (90 minutes at most). Replaced on every new build so a rebuild waits again.
resource "terraform_data" "image_ready" {
  count = local.build_image ? 1 : 0

  depends_on = [oci_core_instance.jumphost]

  triggers_replace = [local.image_base]

  provisioner "local-exec" {
    command = "${path.module}/scripts/wait-for-image.sh"
    environment = {
      DONE_URL        = local.read_done_url
      TIMEOUT_SECONDS = local.image_build_timeout
      POLL_SECONDS    = 30
    }
  }
}
