module "elemental_config" {
  source = "../elemental-config"

  cluster_name = var.cluster_name
  api_vip      = local.api_vip
  api_host     = local.api_host
  vpc_cidr     = local.vpc_cidr
  rke2_token   = random_password.token.result
  tls_san      = [aws_lb.api.dns_name, aws_lb.public.dns_name, local.api_vip]

  nodes = [
    for n in concat(local.control_plane_nodes, local.agent_nodes) : {
      hostname = n.hostname
      type     = n.type
      init     = n.init
      node_ip  = n.private_ip
      role     = n.role
      pool     = n.pool
    }
  ]

  user_data_max_bytes = 16384
  compress_node_files = true
  kernel_cmdline      = "console=ttyS0 ignition.platform.id=aws"

  canal_iface_regex    = null
  pod_veth_mtu         = local.pod_veth_mtu
  enable_write_node_ip = false

  root_password_hash      = var.root_password_hash
  node_user_password_hash = var.node_user_password_hash
  node_username           = var.node_username
  ssh_authorized_keys     = var.ssh_authorized_keys
  permit_root_ssh         = var.permit_root_ssh

  elemental_image    = var.elemental_image
  image_disk_size    = var.image_disk_size
  fips               = var.fips
  components         = var.components
  suse_storage_nodes = var.suse_storage_nodes
  ingress_controller = var.ingress_controller
  api_vip_mode       = "external"

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

  image_rebuild = var.image_rebuild

  extra_build_inputs = {
    factory = module.image_factory.script_hash
  }
}
