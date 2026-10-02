# The original (non-VPC 2.0) VPC, the one wired to vpc_id and vpc_only. The
# subnet is explicit so the range shows in a diff.
resource "vultr_vpc" "this" {
  region         = var.region
  description    = "${var.cluster_name}-vpc"
  v4_subnet      = local.vpc_network
  v4_subnet_mask = local.vpc_prefix

  # Plan-time input checks; every node depends on the VPC.
  lifecycle {
    precondition {
      condition     = length(var.zones) <= 1
      error_message = "zones must have at most one entry: this provider has a single location per deployment."
    }

    precondition {
      condition     = var.region != null
      error_message = "region is required on this provider, for example \"ams\"."
    }

    precondition {
      condition     = var.control_plane_disk_size_gb == null && var.jumphost_disk_size_gb == null
      error_message = "control_plane_disk_size_gb and jumphost_disk_size_gb must be null: the plan fixes the disk size."
    }

    precondition {
      condition     = !var.control_plane_public_ip
      error_message = "control_plane_public_ip must be false: control-plane nodes have no public NIC, egress goes through the NAT gateway."
    }

    precondition {
      condition     = length(local.agent_pool_unsupported) == 0
      error_message = "gpu_pools or worker_pools entries ${join(", ", local.agent_pool_unsupported)} set a field this provider does not support: zone, disk_size_gb and placement must be null."
    }

    precondition {
      condition     = length(local.agent_pool_bad_kind) == 0
      error_message = "gpu_pools or worker_pools entries ${join(", ", local.agent_pool_bad_kind)} mix plan family and kind: kind = \"bare_metal\" needs a vbm-* instance_type, kind = \"vm\" a cloud plan."
    }
  }
}

# Egress for vpc_only nodes. Also the source address the load balancer sees on
# 9345 joins: apiVIP is the load balancer's public address, so they leave the VPC.
resource "vultr_nat_gateway" "this" {
  vpc_id = vultr_vpc.this.id
  label  = "${var.cluster_name}-nat"
  tag    = "elemental-cluster=${var.cluster_name}"
}
