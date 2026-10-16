provider "vultr" {
  api_key = var.vultr_api_key
}

module "ai_factory" {
  source = "../../modules/vultr"

  cluster_name  = var.cluster_name
  region        = var.region
  admin_cidrs   = var.admin_cidrs
  api_cidrs     = var.api_cidrs
  ingress_cidrs = var.ingress_cidrs
  tags          = var.tags
  deploy_nodes  = var.deploy_nodes

  control_plane_count         = var.control_plane_count
  control_plane_instance_type = var.control_plane_instance_type
  jumphost_instance_type      = var.jumphost_instance_type
  gpu_pools                   = var.gpu_pools
  worker_pools                = var.worker_pools
  image_id                    = var.image_id
  image_rebuild               = var.image_rebuild
  aif_release                 = var.aif_release
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

  vultr_api_key = var.vultr_api_key
  ssh_key_ids   = var.ssh_key_ids
  mdisk_mode    = var.mdisk_mode

  # Empty on pass 1; deploy.sh fills them on pass 2 (image/load balancer cycle).
  lb_backend_instance_ids   = var.lb_backend_instance_ids
  lb_supervisor_extra_cidrs = var.lb_supervisor_extra_cidrs
  agent_cloud_extra_cidrs   = var.agent_cloud_extra_cidrs
  image_import_port_open    = var.image_import_port_open
}
