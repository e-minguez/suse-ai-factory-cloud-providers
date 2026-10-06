# Control planes are one instance pool: the NLB targets pools only. One
# Ignition entry for every member; pass 1 runs a single member with the init
# configuration, pass 2 switches to the join configuration and scales up
# (docs/decisions/008-exoscale-module.md). Only the init entry can bootstrap a
# cluster, and it is only rendered while cp_initialized is false.

resource "exoscale_anti_affinity_group" "control_plane" {
  name        = "${var.cluster_name}-control-plane"
  description = "Spreads the control plane pool members over hypervisors"
}

resource "exoscale_instance_pool" "control_plane" {
  count = var.deploy_nodes ? 1 : 0

  depends_on = [terraform_data.api_check]

  zone            = local.zone
  name            = local.control_plane_prefix
  instance_prefix = local.control_plane_prefix
  size            = local.control_plane_size
  template_id     = local.effective_template_id
  instance_type   = local.control_plane_type
  disk_size       = local.control_plane_disk_gb

  network_ids             = [exoscale_private_network.this.id]
  security_group_ids      = [exoscale_security_group.control_plane.id]
  anti_affinity_group_ids = [exoscale_anti_affinity_group.control_plane.id]

  labels = merge(local.labels, {
    "elemental-role"  = "control_plane"
    "elemental-pool"  = "cp"
    "elemental-build" = module.config.build_id
  })

  # Raw Ignition JSON (ignition.platform.id=exoscale). A change updates the
  # pool in place and reaches new members only: Ignition runs on first boot.
  user_data = module.config.node_runtime_ignition[local.control_plane_prefix]
}

# Pass 1 ends once the first member answers through the NLB, so deploy.sh only
# pins cp_initialized = true on a working cluster. Polled from the operator
# machine on 6443, which api_cidrs must admit.
resource "terraform_data" "cp_init_ready" {
  count = var.deploy_nodes && !var.cp_initialized ? 1 : 0

  depends_on = [exoscale_nlb_service.api]

  triggers_replace = [one(exoscale_instance_pool.control_plane[*].id)]

  provisioner "local-exec" {
    command = "${path.module}/scripts/wait-for-cp-init.sh"
    environment = {
      API_URL         = "https://${local.api_vip}:6443/readyz"
      TIMEOUT_SECONDS = 1800
      POLL_SECONDS    = 15
    }
  }
}

# Current members with their privnet lease: Terraform exposes neither the
# lease nor, right after a scale call, the new members. depends_on defers the
# read to the apply that changes the pool.
data "external" "cp_members" {
  count = var.deploy_nodes ? 1 : 0

  depends_on = [exoscale_instance_pool.control_plane, terraform_data.cp_init_ready]

  program = ["bash", "${path.module}/scripts/exoscale-api.sh"]

  query = {
    mode       = "members"
    zone       = local.zone
    api_key    = var.exoscale_api_key
    api_secret = var.exoscale_api_secret
    pool_id    = one(exoscale_instance_pool.control_plane[*].id)
    network_id = exoscale_private_network.this.id
  }
}

locals {
  cp_members = var.deploy_nodes ? jsondecode(one(data.external.cp_members[*].result.members)) : []
}
