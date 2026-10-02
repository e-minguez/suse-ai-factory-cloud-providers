locals {
  # Applied to every resource either provider creates; the module's own tags
  # (var.tags) take precedence on conflicts. Adjust to your organization.
  default_tags = {
    Example   = "aws"
    ManagedBy = "terraform"
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.default_tags
  }
}

# Node instances only. The SDK retries InsufficientInstanceCapacity (HTTP 500)
# up to max_retries and ignores resource timeouts (docs/workarounds.md).
provider "aws" {
  alias       = "nodes"
  region      = var.region
  max_retries = 3

  default_tags {
    tags = local.default_tags
  }
}

module "ai_factory" {
  source = "../../modules/aws"

  providers = {
    aws       = aws
    aws.nodes = aws.nodes
  }

  region       = var.region
  zones        = var.zones
  cluster_name = var.cluster_name

  admin_cidrs   = var.admin_cidrs
  api_cidrs     = var.api_cidrs
  ingress_cidrs = var.ingress_cidrs
  api_host      = var.api_host
  tags          = var.tags

  deploy_nodes                = var.deploy_nodes
  control_plane_count         = var.control_plane_count
  control_plane_instance_type = var.control_plane_instance_type
  control_plane_disk_size_gb  = var.control_plane_disk_size_gb
  gpu_pools                   = var.gpu_pools
  worker_pools                = var.worker_pools

  jumphost_instance_type = var.jumphost_instance_type
  jumphost_disk_size_gb  = var.jumphost_disk_size_gb
  image_id               = var.image_id
  keep_build_artifacts   = var.keep_build_artifacts

  vmimport_role_name             = var.vmimport_role_name
  jumphost_instance_profile_name = var.jumphost_instance_profile_name

  image_rebuild      = var.image_rebuild
  aif_release        = var.aif_release
  components         = var.components
  suse_storage_nodes = var.suse_storage_nodes

  root_password_hash      = var.root_password_hash
  node_username           = var.node_username
  node_user_password_hash = var.node_user_password_hash
  ssh_authorized_keys     = var.ssh_authorized_keys
  permit_root_ssh         = var.permit_root_ssh

  appco_username         = var.appco_username
  appco_password         = var.appco_password
  appco_registry         = var.appco_registry
  suse_registry_username = var.suse_registry_username
  suse_registry_password = var.suse_registry_password
  nvidia_api_key         = var.nvidia_api_key
  nvidia_username        = var.nvidia_username
  gpu_driver_repository  = var.gpu_driver_repository
  gpu_driver_version     = var.gpu_driver_version

  rancher_hostname           = var.rancher_hostname
  rancher_bootstrap_password = var.rancher_bootstrap_password
}
