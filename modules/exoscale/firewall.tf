# Private network mode: security groups filter public interfaces only, so
# intra-cluster traffic and SSH from the jumphost are not subject to them.
# Public mode: nodes talk over their public IPv4, so SG-to-SG rules admit the
# cluster ports (never a CIDR). No egress rules: Exoscale allows all egress
# until the first egress rule. The jumphost is the only SSH entry.

module "rke2_ports" {
  source = "../rke2-ports"

  ingress_controller = var.ingress_controller
}

resource "exoscale_security_group" "jumphost" {
  name        = "${var.cluster_name}-jumphost"
  description = "SSH from admin_cidrs; tcp/80 during the image import"
}

resource "exoscale_security_group" "control_plane" {
  name        = "${var.cluster_name}-control-plane"
  description = "NLB services: API from api_cidrs, ingress from ingress_cidrs, healthchecks"
}

resource "exoscale_security_group" "agent" {
  name        = "${var.cluster_name}-agent"
  description = local.private_mode ? "No inbound rules: agents are reached over the private network" : "Cluster ports from control plane and agent nodes, SSH from the jumphost"
}

resource "exoscale_security_group_rule" "jumphost_ssh" {
  for_each = toset(var.admin_cidrs)

  security_group_id = exoscale_security_group.jumphost.id
  type              = "INGRESS"
  protocol          = "TCP"
  cidr              = each.value
  start_port        = 22
  end_port          = 22
  description       = "ssh from admin_cidrs"
}

locals {
  ingress_ports = [for k, v in module.rke2_ports.lb_ingress : v.from]

  # Healthcheck ports: the API ports and each ingress check port (Traefik
  # /ping on 8080, or the listener port itself).
  healthcheck_ports = distinct(concat(
    [for k, v in module.rke2_ports.lb_api : v.from],
    [for k, h in module.rke2_ports.lb_ingress_health : h.port],
  ))

  # The NLB keeps the client address. Nodes reach the API through it from their
  # public IPs (joins on 9345), hence the security group sources.
  control_plane_rules = merge(
    { for c in var.api_cidrs : "api-${c}" => { port = 6443, cidr = c, sg = null, public_sg = null } },
    { for pair in setproduct(local.ingress_ports, var.ingress_cidrs) : "ingress-${pair[0]}-${pair[1]}" => { port = pair[0], cidr = pair[1], sg = null, public_sg = null } },
    { for pair in setproduct([for k, v in module.rke2_ports.lb_api : v.from], ["control_plane", "agent"]) : "nodes-${pair[0]}-${pair[1]}" => {
      port = pair[0], cidr = null, sg = pair[1], public_sg = null
    } },
    { for p in local.healthcheck_ports : "healthcheck-${p}" => { port = p, cidr = null, sg = null, public_sg = "public-nlb-healthcheck-sources" } },
  )

  security_group_ids = {
    control_plane = exoscale_security_group.control_plane.id
    agent         = exoscale_security_group.agent.id
  }
}

resource "exoscale_security_group_rule" "control_plane" {
  for_each = local.control_plane_rules

  security_group_id      = exoscale_security_group.control_plane.id
  type                   = "INGRESS"
  protocol               = "TCP"
  cidr                   = each.value.cidr
  user_security_group_id = each.value.sg == null ? null : local.security_group_ids[each.value.sg]
  public_security_group  = each.value.public_sg
  start_port             = each.value.port
  end_port               = each.value.port
  description            = each.key
}

# Public mode: etcd, the node ports and VXLAN (8472/udp) come from
# module.rke2_ports; the API ports are already admitted by "nodes-*" in
# control_plane_rules.
locals {
  node_ports = module.rke2_ports.worker

  etcd_ports = {
    for k, v in module.rke2_ports.control_plane : k => v
    if !contains(keys(module.rke2_ports.lb_api), k) && !contains(keys(module.rke2_ports.control_plane_ingress), k) && !contains(keys(module.rke2_ports.worker), k)
  }

  # Ports each role accepts, and from which security groups.
  intra_sources = {
    control_plane = {
      sources = ["control_plane", "agent"]
      ports   = merge(local.etcd_ports, local.node_ports)
    }
    agent = {
      sources = ["control_plane", "agent"]
      ports   = local.node_ports
    }
  }

  # etcd only between control planes: agents never dial it.
  intra_rules = local.private_mode ? {} : merge([
    for dst, d in local.intra_sources : {
      for pair in setproduct(d.sources, keys(d.ports)) :
      "${dst}-${pair[0]}-${pair[1]}" => merge(d.ports[pair[1]], { dst = dst, src = pair[0] })
      if !(pair[0] == "agent" && contains(keys(local.etcd_ports), pair[1]))
    }
  ]...)

  ssh_rules = local.private_mode ? {} : { for dst in ["control_plane", "agent"] : "ssh-jumphost-${dst}" => dst }
}

resource "exoscale_security_group_rule" "intra" {
  for_each = local.intra_rules

  security_group_id      = local.security_group_ids[each.value.dst]
  type                   = "INGRESS"
  protocol               = upper(each.value.protocol)
  user_security_group_id = local.security_group_ids[each.value.src]
  start_port             = each.value.from
  end_port               = each.value.to
  description            = each.key
}

resource "exoscale_security_group_rule" "ssh_from_jumphost" {
  for_each = local.ssh_rules

  security_group_id      = local.security_group_ids[each.value]
  type                   = "INGRESS"
  protocol               = "TCP"
  user_security_group_id = exoscale_security_group.jumphost.id
  start_port             = 22
  end_port               = 22
  description            = each.key
}
