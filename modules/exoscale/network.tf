# Managed private network (L2, zone-local, MTU 1500) carrying all cluster
# traffic. Security groups do not filter traffic inside it.
resource "exoscale_private_network" "this" {
  zone     = local.zone
  name     = "${var.cluster_name}-net"
  netmask  = cidrnetmask(local.vpc_cidr)
  start_ip = local.dhcp_start_ip
  end_ip   = local.dhcp_end_ip
  labels   = merge(local.labels, { "elemental-role" = "network" })

  # Plan-time input checks; every node depends on the network.
  lifecycle {
    precondition {
      condition     = length(var.zones) <= 1
      error_message = "zones must have at most one entry: an Exoscale zone is the whole location (region), and private networks and instance pools cannot span zones."
    }

    precondition {
      condition     = local.vpc_prefix >= 16 && local.vpc_prefix <= 26
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
  }
}
