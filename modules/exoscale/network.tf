# Plan-time input checks. Kept off the network, which does not exist with
# private_network_id.
resource "terraform_data" "input_checks" {
  lifecycle {
    precondition {
      condition     = length(var.zones) <= 1
      error_message = "zones must have at most one entry: an Exoscale zone is the whole location (region), and private networks and instance pools cannot span zones."
    }

    precondition {
      condition     = var.private_network_id != null || (tonumber(split("/", local.vpc_cidr_new)[1]) >= 16 && tonumber(split("/", local.vpc_cidr_new)[1]) <= 26)
      error_message = "vpc_cidr must be a /16 to /26: the private network needs room for the DHCP range above the jumphost lease."
    }

    precondition {
      condition     = local.vpc_mtu <= 1500
      error_message = "vpc_mtu must be at most 1500: Exoscale private networks do not support jumbo frames."
    }

    precondition {
      condition     = var.control_plane_count <= 8
      error_message = "control_plane_count must be at most 8: the control plane pool uses one anti-affinity group, which holds 8 instances."
    }

    precondition {
      condition     = length(local.control_plane_prefix) <= 30
      error_message = "cluster_name must be at most 27 characters on this provider: the control plane pool's instance_prefix \"<cluster_name>-cp\" is limited to 30."
    }

    # Rejected rather than ignored: every node gets a public IPv4 on this
    # provider, and nobody should get one without asking for it.
    precondition {
      condition     = var.control_plane_public_ip
      error_message = "control_plane_public_ip must be true: every Exoscale node has a public IPv4 (the NLB returns traffic from it, Ignition needs the metadata service, and egress uses it). Security groups filter it. See docs/providers/exoscale.md#limitations."
    }

    precondition {
      condition     = length(local.agent_pool_private) == 0
      error_message = "gpu_pools or worker_pools entries ${join(", ", local.agent_pool_private)} need public_ip = true: every Exoscale node has a public IPv4 (egress and the metadata service), with no inbound rules for worker and GPU nodes. See docs/providers/exoscale.md#limitations."
    }

    precondition {
      condition     = length(local.agent_pool_unsupported) == 0
      error_message = "gpu_pools or worker_pools entries ${join(", ", local.agent_pool_unsupported)} set a field this provider does not support: zone and placement must be null and kind must be \"vm\"."
    }

    # Range checks of an existing network; here, not on the data source, because
    # the range locals derive from it.
    precondition {
      condition     = var.private_network_id == null || var.vpc_cidr == null || local.existing_network_cidr == var.vpc_cidr
      error_message = "vpc_cidr (${coalesce(var.vpc_cidr, "null")}) does not match the range of private network ${coalesce(var.private_network_id, "-")}, ${coalesce(local.existing_network_cidr, "-")}. Leave vpc_cidr null with private_network_id."
    }

    # Same rule as the vpc_cidr validation (variables-common.tf).
    precondition {
      condition = local.existing_network_cidr == null || !anytrue([
        for c in ["10.42.0.0/16", "10.43.0.0/16"] :
        cidrhost(format("%s/%d", cidrhost(local.existing_network_cidr, 0), min(local.existing_network_prefix, 16)), 0) == cidrhost(format("%s/%d", cidrhost(c, 0), min(local.existing_network_prefix, 16)), 0)
      ])
      error_message = "The range of private network ${coalesce(var.private_network_id, "-")}, ${coalesce(local.existing_network_cidr, "-")}, overlaps the RKE2 default cluster-cidr 10.42.0.0/16 or service-cidr 10.43.0.0/16."
    }
  }
}

# Managed private network (L2, zone-local, MTU 1500) carrying all cluster
# traffic. Security groups do not filter traffic inside it. Not created with
# var.private_network_id.
resource "exoscale_private_network" "this" {
  count = var.private_network_id == null ? 1 : 0

  zone     = local.zone
  name     = "${var.cluster_name}-net"
  netmask  = cidrnetmask(local.vpc_cidr_new)
  start_ip = local.dhcp_start_ip
  end_ip   = local.dhcp_end_ip
  labels   = merge(local.labels, { "elemental-role" = "network" })
}

moved {
  from = exoscale_private_network.this
  to   = exoscale_private_network.this[0]
}

# --- Existing network (var.private_network_id) --------------------------------
#
# Read only: destroy leaves the network in place.
data "exoscale_private_network" "existing" {
  count = var.private_network_id != null ? 1 : 0

  zone = local.zone
  id   = var.private_network_id

  lifecycle {
    # Nodes and control plane pool members take their private address by DHCP.
    postcondition {
      condition     = try(self.netmask != "" && self.start_ip != "" && self.end_ip != "", false)
      error_message = "Private network ${var.private_network_id} must be managed (netmask and DHCP range set): nodes take their private address by DHCP."
    }
  }
}

locals {
  private_network_id = var.private_network_id != null ? data.exoscale_private_network.existing[0].id : exoscale_private_network.this[0].id

  # The data source returns netmask and DHCP range, not a CIDR: count the mask bits.
  netmask_octet_bits = { "255" = 8, "254" = 7, "252" = 6, "248" = 5, "240" = 4, "224" = 3, "192" = 2, "128" = 1, "0" = 0 }
  existing_network_prefix = var.private_network_id != null ? try(sum([
    for o in split(".", data.exoscale_private_network.existing[0].netmask) : local.netmask_octet_bits[o]
  ]), null) : null
  existing_network_cidr = local.existing_network_prefix == null ? null : try(
    "${cidrhost("${data.exoscale_private_network.existing[0].start_ip}/${local.existing_network_prefix}", 0)}/${local.existing_network_prefix}", null
  )
}
