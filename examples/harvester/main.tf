provider "harvester" {
  kubeconfig  = var.harvester_kubeconfig_path
  kubecontext = var.harvester_kubecontext
}

module "ai_factory" {
  source = "../../modules/harvester"

  cluster_name  = var.cluster_name
  region        = var.region
  zones         = var.zones
  admin_cidrs   = var.admin_cidrs
  api_cidrs     = var.api_cidrs
  ingress_cidrs = var.ingress_cidrs
  tags          = var.tags
  deploy_nodes  = var.deploy_nodes

  control_plane_count         = var.control_plane_count
  control_plane_instance_type = var.control_plane_instance_type
  control_plane_disk_size_gb  = var.control_plane_disk_size_gb
  control_plane_public_ip     = var.control_plane_public_ip
  jumphost_instance_type      = var.jumphost_instance_type
  jumphost_disk_size_gb       = var.jumphost_disk_size_gb
  jumphost_image              = var.jumphost_image
  jumphost_username           = var.jumphost_username
  keep_build_artifacts        = var.keep_build_artifacts
  gpu_pools                   = var.gpu_pools
  worker_pools                = var.worker_pools
  image_id                    = var.image_id
  vpc_cidr                    = var.vpc_cidr
  vpc_id                      = var.vpc_id
  image_rebuild               = var.image_rebuild
  aif_release                 = var.aif_release
  etcd_unsafe_no_fsync        = var.etcd_unsafe_no_fsync
  components                  = var.components
  suse_storage_nodes          = var.suse_storage_nodes

  root_password_hash      = var.root_password_hash
  node_username           = var.node_username
  node_user_password_hash = var.node_user_password_hash
  ssh_authorized_keys     = var.ssh_authorized_keys
  permit_root_ssh         = var.permit_root_ssh

  appco_username             = var.appco_username
  appco_password             = var.appco_password
  appco_registry             = var.appco_registry
  suse_registry_username     = var.suse_registry_username
  suse_registry_password     = var.suse_registry_password
  nvidia_api_key             = var.nvidia_api_key
  nvidia_username            = var.nvidia_username
  rancher_hostname           = var.rancher_hostname
  ingress_domain             = var.ingress_domain
  rancher_bootstrap_password = var.rancher_bootstrap_password

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

  harvester_namespace  = var.harvester_namespace
  api_vip              = var.api_vip
  ingress_vip          = var.ingress_vip
  storage_class_name   = var.storage_class_name
  disk_cache_mode      = var.disk_cache_mode
  node_storage_classes = var.node_storage_classes
  buildhost_image_url  = var.buildhost_image_url
  buildhost_power_off  = var.buildhost_power_off
  gpu_devices          = var.gpu_devices
}
