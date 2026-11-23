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
  tls_san      = [local.external_address]
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

  # One metadata value holds 256 KiB (262144 bytes); the margin covers the
  # attribute envelope. Ignition's gcp provider does not gunzip, and the limit is
  # far above a node's config, so files are not compressed.
  user_data_max_bytes = 245760
  compress_node_files = false
  kernel_cmdline      = "console=ttyS0,115200n8 ignition.platform.id=gcp"

  # Control planes route both load balancer addresses locally: a passthrough
  # backend receives packets for the address but does not own it. The internal
  # one is added after rke2-server is active, so a joining control plane
  # reaches an existing server through the load balancer instead of itself.
  local_route_addresses              = [local.external_address]
  local_route_addresses_after_server = [local.api_vip]

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

  ingress_address = local.external_address

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

  # Single NIC per node: RKE2 picks the right address without write-node-ip.
  enable_write_node_ip = false

  image_rebuild = var.image_rebuild

  # The factory script is provider-owned and not in the config dir.
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

# Target disk -> snapshot -> global image. The jumphost (build.tf) only writes the
# disk; Terraform owns snapshot and image, so `terraform destroy` removes both. An
# image_id pinned that way must not be one this module owns.
locals {
  # image_base is also the image name, e.g. "suse-ai-factory-1a2b3c4d5e6f".
  image_base = "${var.cluster_name}-${module.config.build_id}"

  image_labels = merge(local.labels, { "elemental-role" = "image", "elemental-build" = module.config.build_id })
}

# Taken from the attached disk after the jumphost reported done (the data is
# synced). Terraform cannot force an image from an attached disk, a snapshot is
# allowed.
resource "google_compute_snapshot" "ai_factory" {
  count = local.build_image ? 1 : 0

  depends_on = [terraform_data.image_ready]

  name              = local.image_base
  description       = "Elemental image of ${var.cluster_name}, build ${module.config.build_id}"
  source_disk       = google_compute_disk.image_target[0].self_link
  zone              = local.zones[0]
  storage_locations = [local.region]
  labels            = local.image_labels

  timeouts {
    create = "30m"
  }
}

resource "google_compute_image" "ai_factory" {
  count = local.build_image ? 1 : 0

  name              = local.image_base
  description       = "SUSE AI Factory Elemental image, build ${module.config.build_id}"
  source_snapshot   = google_compute_snapshot.ai_factory[0].self_link
  storage_locations = [local.region]
  labels            = local.image_labels

  guest_os_features {
    type = "UEFI_COMPATIBLE"
  }

  guest_os_features {
    type = "GVNIC"
  }

  guest_os_features {
    type = "VIRTIO_SCSI_MULTIQUEUE"
  }

  timeouts {
    create = "60m"
  }
}

locals {
  # one(): the image has count = 0 when image_id is set.
  effective_image_id = var.image_id != null ? var.image_id : one(google_compute_image.ai_factory[*].self_link)
}
