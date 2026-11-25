# Everything baked into the image (release.yaml, butane.yaml, RKE2 config, Helm
# values) and every node's Ignition user_data come from the shared module.
# build_hash is the only rebuild trigger.
module "config" {
  source = "../elemental-config"

  cluster_name = var.cluster_name
  api_vip      = var.api_vip
  api_host     = local.api_host
  api_vip_mode = local.api_vip_mode
  ingress_vip  = var.ingress_controller == "none" ? null : var.ingress_vip
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

  # user_data sits in a Secret (1 MiB limit) and the NoCloud platform reads it
  # as plain Ignition JSON: no compression.
  user_data_max_bytes = 900000
  compress_node_files = false
  kernel_cmdline      = "console=ttyS0 ignition.platform.id=kubevirt"

  pod_veth_mtu       = local.pod_veth_mtu
  ingress_controller = var.ingress_controller
  components         = var.components
  suse_storage_nodes = var.suse_storage_nodes

  elemental_image      = var.elemental_image
  image_disk_size      = var.image_disk_size
  fips                 = var.fips
  etcd_unsafe_no_fsync = var.etcd_unsafe_no_fsync

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

  ingress_address = var.ingress_vip

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

  # One NIC per VM: RKE2 picks the right address without write-node-ip.
  enable_write_node_ip = false

  # The factory script is provider-owned and not in the config dir.
  image_rebuild = var.image_rebuild

  extra_build_inputs = local.extra_build_inputs
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
