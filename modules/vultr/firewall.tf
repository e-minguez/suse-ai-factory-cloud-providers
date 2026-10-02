# Jumphost group: the only public admin entrypoint. The port 80 rule for the
# snapshot import is vultr_firewall_rule.image_import (image.tf).
resource "vultr_firewall_group" "jumphost" {
  description = "${var.cluster_name}-jumphost"
}

resource "vultr_firewall_rule" "jumphost_ssh" {
  for_each = toset(var.admin_cidrs)

  firewall_group_id = vultr_firewall_group.jumphost.id
  protocol          = "tcp"
  ip_type           = "v4"
  subnet            = split("/", each.value)[0]
  subnet_size       = tonumber(split("/", each.value)[1])
  port              = "22"
  notes             = "ssh from admin_cidrs"
}

# Control-plane group, attached although vpc_only nodes have no public NIC.
# Every rule is scoped to the VPC subnet.
resource "vultr_firewall_group" "control_plane" {
  description = "${var.cluster_name}-control-plane"
}

module "rke2_ports" {
  source = "../rke2-ports"

  ingress_controller = var.ingress_controller
}

locals {
  # Vultr rules take a single port string: "N" or "N:M" for a range.
  control_plane_rules = merge(
    { ssh = { protocol = "tcp", port = "22" } },
    {
      for k, v in module.rke2_ports.control_plane : k => {
        protocol = v.protocol
        port     = v.from == v.to ? tostring(v.from) : "${v.from}:${v.to}"
      }
    },
  )
}

resource "vultr_firewall_rule" "control_plane" {
  for_each = local.control_plane_rules

  firewall_group_id = vultr_firewall_group.control_plane.id
  protocol          = each.value.protocol
  ip_type           = "v4"
  subnet            = local.vpc_network
  subnet_size       = local.vpc_prefix
  port              = each.value.port
  notes             = each.key
}

# Cloud agents (GPU and worker pools): vultr_instance takes a firewall_group_id,
# vultr_bare_metal_server does not (docs/providers/vultr.md#security). Created
# only when a cloud agent exists.
resource "vultr_firewall_group" "agent_cloud" {
  count = length(local.agent_cloud_nodes) > 0 ? 1 : 0

  description = "${var.cluster_name}-agent-cloud"
}

locals {
  agent_cloud_rules = {
    for k, v in module.rke2_ports.worker : k => {
      protocol = v.protocol
      port     = v.from == v.to ? tostring(v.from) : "${v.from}:${v.to}"
    }
  }

  # VPC subnet, plus the NAT gateway public /32s (agent_cloud_extra_cidrs) for
  # control-plane traffic that reaches an agent's public address.
  agent_cloud_rule_sources = concat([local.vpc_cidr], var.agent_cloud_extra_cidrs)

  agent_cloud_firewall_rules = merge(
    {
      for pair in setproduct(keys(local.agent_cloud_rules), local.agent_cloud_rule_sources) :
      "${pair[0]}-${pair[1]}" => {
        protocol = local.agent_cloud_rules[pair[0]].protocol
        port     = local.agent_cloud_rules[pair[0]].port
        cidr     = pair[1]
        notes    = "${pair[0]} from ${pair[1]}"
      }
    },
    # SSH from admin_cidrs only.
    {
      for cidr in var.admin_cidrs : "ssh-${cidr}" => {
        protocol = "tcp"
        port     = "22"
        cidr     = cidr
        notes    = "ssh from admin_cidrs"
      }
    },
  )
}

resource "vultr_firewall_rule" "agent_cloud" {
  for_each = length(local.agent_cloud_nodes) > 0 ? local.agent_cloud_firewall_rules : {}

  firewall_group_id = one(vultr_firewall_group.agent_cloud[*].id)
  protocol          = each.value.protocol
  ip_type           = "v4"
  subnet            = split("/", each.value.cidr)[0]
  subnet_size       = tonumber(split("/", each.value.cidr)[1])
  port              = each.value.port
  notes             = each.value.notes
}
