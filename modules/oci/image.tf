# Everything baked into the image (release.yaml, butane.yaml, RKE2 config, Helm
# values) and every node's Ignition user_data come from the shared module.
# build_hash is the only rebuild trigger.
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
    for n in local.ignition_nodes : {
      hostname = n.hostname
      type     = n.type
      role     = n.role
      init     = n.init
      pool     = n.pool
    }
  ]

  # Metadata (user_data in base64, plus the ssh keys) is capped at 32000 bytes:
  # 32000 * 3/4 = 24000, minus a margin for ssh_authorized_keys and the key names.
  # The oraclecloud provider does not gunzip user_data, so files are compressed one by one.
  user_data_max_bytes = 22000
  compress_node_files = true
  kernel_cmdline      = "console=ttyS0,115200n8 console=tty0 quiet ignition.platform.id=oraclecloud"

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
  ingress_domain             = var.ingress_domain
  rancher_bootstrap_password = var.rancher_bootstrap_password

  ingress_address = local.api_vip

  security_admin_password              = var.security_admin_password
  security_hostname                    = var.security_hostname
  security_join_token                  = var.security_join_token
  security_primary_endpoint            = var.security_primary_endpoint
  security_rancher_url                 = var.security_rancher_url
  observability_license_key            = var.observability_license_key
  observability_admin_password         = var.observability_admin_password
  observability_sizing_profile         = var.observability_sizing_profile
  observability_hostname               = var.observability_hostname
  observability_bootstrap_token        = var.observability_bootstrap_token
  observability_server_url             = var.observability_server_url
  observability_ca_pem                 = var.observability_ca_pem
  observability_allowed_origins        = var.observability_allowed_origins
  observability_suse_ai_namespace      = var.observability_suse_ai_namespace
  observability_opensearch_credentials = var.observability_opensearch_credentials

  # Single VNIC per node: RKE2 picks the right address without write-node-ip.
  enable_write_node_ip = false

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

# Object Storage qcow2 -> custom image. The jumphost (build.tf) only uploads;
# Terraform owns the image, so `terraform destroy` removes it. An image_id
# pinned that way must not be one this module owns.
locals {
  # image_base is also the image name, e.g. "suse-ai-factory-1a2b3c4d5e6f".
  image_base = "${var.cluster_name}-${module.config.build_id}"
}

resource "oci_core_image" "ai_factory" {
  count = local.build_image ? 1 : 0

  depends_on = [terraform_data.image_ready]

  compartment_id = var.oci_compartment_ocid
  display_name   = local.image_base
  launch_mode    = "PARAVIRTUALIZED"
  freeform_tags = merge(local.labels, {
    "elemental-role"  = "image"
    "elemental-build" = module.config.build_id
  })

  image_source_details {
    source_type       = "objectStorageTuple"
    namespace_name    = data.oci_objectstorage_namespace.this.namespace
    bucket_name       = local.bucket_name
    object_name       = local.qcow_key
    source_image_type = "QCOW2"
  }

  timeouts {
    create = "120m"
  }
}

# Imported images boot with BIOS firmware; the capability schema switches them to UEFI.
data "oci_core_compute_global_image_capability_schemas" "this" {}

resource "oci_core_compute_image_capability_schema" "uefi" {
  count = local.build_image ? 1 : 0

  compartment_id = var.oci_compartment_ocid
  display_name   = local.image_base
  image_id       = oci_core_image.ai_factory[0].id
  freeform_tags  = merge(local.labels, { "elemental-role" = "image", "elemental-build" = module.config.build_id })

  compute_global_image_capability_schema_version_name = data.oci_core_compute_global_image_capability_schemas.this.compute_global_image_capability_schemas[0].current_version_name

  schema_data = {
    "Compute.Firmware" = jsonencode({
      descriptorType = "enumstring"
      source         = "IMAGE"
      defaultValue   = "UEFI_64"
      values         = ["UEFI_64"]
    })
  }
}

# GPU shapes the image must be compatible with (VM shapes only).
resource "oci_core_shape_management" "gpu" {
  for_each = local.build_image ? toset([for k, p in var.gpu_pools : local.shapes[p.instance_type].name if p.count > 0]) : toset([])

  compartment_id = var.oci_compartment_ocid
  image_id       = oci_core_image.ai_factory[0].id
  shape_name     = each.value

  depends_on = [oci_core_compute_image_capability_schema.uefi]
}

# Objects written through a PAR are not Terraform's: once the image is imported,
# these overwrite them with a one-line object, so destroy deletes both and then
# the bucket. keep_build_artifacts keeps the qcow2 in the bucket; delete it
# before destroying.
resource "oci_objectstorage_object" "qcow_cleanup" {
  count = local.build_image && !var.keep_build_artifacts ? 1 : 0

  namespace    = data.oci_objectstorage_namespace.this.namespace
  bucket       = local.bucket_name
  object       = local.qcow_key
  content      = "imported into ${local.image_base}"
  content_type = "text/plain"

  depends_on = [oci_core_compute_image_capability_schema.uefi]

  lifecycle {
    ignore_changes = all
    # ignore_changes also blocks the replacement a new object key forces.
    replace_triggered_by = [terraform_data.build_trigger]
  }
}

resource "oci_objectstorage_object" "done_cleanup" {
  count = local.build_image ? 1 : 0

  namespace    = data.oci_objectstorage_namespace.this.namespace
  bucket       = local.bucket_name
  object       = local.done_key
  content      = "imported into ${local.image_base}"
  content_type = "text/plain"

  depends_on = [oci_core_image.ai_factory]

  lifecycle {
    ignore_changes       = all
    replace_triggered_by = [terraform_data.build_trigger]
  }
}

locals {
  # one(): the image has count = 0 when image_id is set.
  effective_image_id = var.image_id != null ? var.image_id : one(oci_core_image.ai_factory[*].id)
}
