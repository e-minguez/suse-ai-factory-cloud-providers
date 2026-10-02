# Security groups: jumphost, api_nlb, public_nlb, control_plane and agent (worker and GPU nodes).
# One rule per resource (aws_vpc_security_group_*_rule), keyed by port name so
# adding a port never replaces a group. References between groups are
# SG-to-SG, so the graph is known at plan time.

module "rke2_ports" {
  source = "../rke2-ports"

  ingress_controller = var.ingress_controller
}

locals {
  # Reshape {protocol, from, to} into the {from_port, to_port} the rule
  # resources use.
  control_plane_ports = {
    for k, v in module.rke2_ports.control_plane : k => { protocol = v.protocol, from_port = v.from, to_port = v.to }
  }
  control_plane_ingress_ports = {
    for k, v in module.rke2_ports.control_plane_ingress : k => { protocol = v.protocol, from_port = v.from, to_port = v.to }
  }
  # Workers dial the API and supervisor on the control plane.
  worker_to_control_plane_ports = merge(local.api_nlb_ports, local.worker_ports)
  worker_ports = {
    for k, v in module.rke2_ports.worker : k => { protocol = v.protocol, from_port = v.from, to_port = v.to }
  }
  api_nlb_ports = {
    for k, v in module.rke2_ports.lb_api : k => { protocol = v.protocol, from_port = v.from, to_port = v.to }
  }
}

# --- jumphost -----------------------------------------------------------

# The sole public admin entrypoint: SSH from admin_cidrs, unrestricted egress.
resource "aws_security_group" "jumphost" {
  name        = "${var.cluster_name}-jumphost"
  description = "Jumphost (build host and bastion): SSH from admin_cidrs, unrestricted egress"
  vpc_id      = aws_vpc.this.id

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-jumphost"
    "elemental-role" = "jumphost"
  })
}

resource "aws_vpc_security_group_ingress_rule" "jumphost_ssh" {
  for_each = toset(var.admin_cidrs)

  security_group_id = aws_security_group.jumphost.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  description       = "ssh from admin_cidrs"

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-jumphost-ssh-${each.value}"
    "elemental-role" = "jumphost"
  })
}

resource "aws_vpc_security_group_egress_rule" "jumphost_all" {
  security_group_id = aws_security_group.jumphost.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "unrestricted egress: S3 upload, AMI import polling, package installs"

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-jumphost-egress-all"
    "elemental-role" = "jumphost"
  })
}

# --- api_nlb -------------------------------------------------------------

# Fronts the internal NLB (loadbalancer.tf). Ingress only, scoped to the VPC
# CIDR; the admin path to 6443 goes through the public NLB.
resource "aws_security_group" "api_nlb" {
  name        = "${var.cluster_name}-api-nlb"
  description = "Internal API/supervisor NLB: 6443+9345 from inside the VPC only"
  vpc_id      = aws_vpc.this.id

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-api-nlb"
    "elemental-role" = "lb"
  })
}

resource "aws_vpc_security_group_ingress_rule" "api_nlb" {
  for_each = local.api_nlb_ports

  security_group_id = aws_security_group.api_nlb.id
  cidr_ipv4         = local.vpc_cidr
  ip_protocol       = each.value.protocol
  from_port         = each.value.from_port
  to_port           = each.value.to_port
  description       = "${each.key} from inside the VPC"

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-api-nlb-${each.key}"
    "elemental-role" = "lb"
  })
}

resource "aws_vpc_security_group_egress_rule" "api_nlb_all" {
  security_group_id = aws_security_group.api_nlb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "unrestricted egress to targets"

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-api-nlb-egress-all"
    "elemental-role" = "lb"
  })
}

# --- public_nlb ------------------------------------------------------------

# Fronts the internet-facing NLB (loadbalancer.tf): ingress listeners plus
# the admin kubectl listener (6443).
locals {
  public_nlb_ingress_ports = merge(
    {
      for pair in setproduct(keys(module.rke2_ports.lb_ingress), var.ingress_cidrs) :
      "${pair[0]}-${pair[1]}" => {
        cidr        = pair[1]
        protocol    = module.rke2_ports.lb_ingress[pair[0]].protocol
        from_port   = module.rke2_ports.lb_ingress[pair[0]].from
        to_port     = module.rke2_ports.lb_ingress[pair[0]].to
        description = "${pair[0]} from ingress_cidrs"
      }
    },
    {
      for cidr in var.api_cidrs : "api-${cidr}" => {
        cidr        = cidr
        protocol    = "tcp"
        from_port   = module.rke2_ports.lb_api.kube_api.from
        to_port     = module.rke2_ports.lb_api.kube_api.to
        description = "kubectl (6443) from api_cidrs"
      }
    },
  )
}

resource "aws_security_group" "public_nlb" {
  name        = "${var.cluster_name}-public-nlb"
  description = "Internet-facing ingress + admin-kubectl NLB"
  vpc_id      = aws_vpc.this.id

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-public-nlb"
    "elemental-role" = "lb"
  })
}

resource "aws_vpc_security_group_ingress_rule" "public_nlb" {
  for_each = local.public_nlb_ingress_ports

  security_group_id = aws_security_group.public_nlb.id
  cidr_ipv4         = each.value.cidr
  ip_protocol       = each.value.protocol
  from_port         = each.value.from_port
  to_port           = each.value.to_port
  description       = each.value.description

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-public-nlb-${each.key}"
    "elemental-role" = "lb"
  })
}

resource "aws_vpc_security_group_egress_rule" "public_nlb_all" {
  security_group_id = aws_security_group.public_nlb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "unrestricted egress to targets"

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-public-nlb-egress-all"
    "elemental-role" = "lb"
  })
}

# --- control_plane -----------------------------------------------------

resource "aws_security_group" "control_plane" {
  name        = "${var.cluster_name}-control-plane"
  description = "RKE2 control plane: full port matrix from itself/workers, LB listeners, ssh from jumphost"
  vpc_id      = aws_vpc.this.id

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-control-plane"
    "elemental-role" = "control_plane"
  })
}

# Control-plane nodes reach each other on the RKE2 ports (self reference).
resource "aws_vpc_security_group_ingress_rule" "control_plane_self" {
  for_each = local.control_plane_ports

  security_group_id            = aws_security_group.control_plane.id
  referenced_security_group_id = aws_security_group.control_plane.id
  ip_protocol                  = each.value.protocol
  from_port                    = each.value.from_port
  to_port                      = each.value.to_port
  description                  = "${each.key} from control_plane (self)"

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-control-plane-self-${each.key}"
    "elemental-role" = "control_plane"
  })
}

# From workers (worker and GPU pools): the worker set plus the API and supervisor they dial.
resource "aws_vpc_security_group_ingress_rule" "control_plane_from_agent" {
  for_each = local.has_agent_pools ? local.worker_to_control_plane_ports : {}

  security_group_id            = aws_security_group.control_plane.id
  referenced_security_group_id = aws_security_group.agent[0].id
  ip_protocol                  = each.value.protocol
  from_port                    = each.value.from_port
  to_port                      = each.value.to_port
  description                  = "${each.key} from worker"

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-control-plane-from-worker-${each.key}"
    "elemental-role" = "control_plane"
  })
}

resource "aws_vpc_security_group_ingress_rule" "control_plane_from_api_nlb" {
  for_each = local.api_nlb_ports

  security_group_id            = aws_security_group.control_plane.id
  referenced_security_group_id = aws_security_group.api_nlb.id
  ip_protocol                  = each.value.protocol
  from_port                    = each.value.from_port
  to_port                      = each.value.to_port
  description                  = "${each.key} from api_nlb"

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-control-plane-from-api-nlb-${each.key}"
    "elemental-role" = "control_plane"
  })
}

# Ingress hostPorts from the ingress NLB; empty without an ingress controller.
# Ingress ports plus the admin kubectl listener (6443) on the same NLB.
resource "aws_vpc_security_group_ingress_rule" "control_plane_from_public_nlb" {
  for_each = merge(local.control_plane_ingress_ports, { kube_api = local.api_nlb_ports.kube_api })

  security_group_id            = aws_security_group.control_plane.id
  referenced_security_group_id = aws_security_group.public_nlb.id
  ip_protocol                  = each.value.protocol
  from_port                    = each.value.from_port
  to_port                      = each.value.to_port
  description                  = "${each.key} from public_nlb"

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-control-plane-from-public-nlb-${each.key}"
    "elemental-role" = "control_plane"
  })
}

resource "aws_vpc_security_group_ingress_rule" "control_plane_ssh_from_jumphost" {
  security_group_id            = aws_security_group.control_plane.id
  referenced_security_group_id = aws_security_group.jumphost.id
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  description                  = "ssh from jumphost"

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-control-plane-ssh-from-jumphost"
    "elemental-role" = "control_plane"
  })
}

resource "aws_vpc_security_group_egress_rule" "control_plane_all" {
  security_group_id = aws_security_group.control_plane.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "unrestricted egress"

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-control-plane-egress-all"
    "elemental-role" = "control_plane"
  })
}

# --- agent ---------------------------------------------------------------

# Only created when there is a pool to attach it to.
resource "aws_security_group" "agent" {
  count = local.has_agent_pools ? 1 : 0

  name        = "${var.cluster_name}-agent"
  description = "Worker and GPU pools: worker ports (no API, etcd or ingress), ssh from jumphost"
  vpc_id      = aws_vpc.this.id

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-agent"
    "elemental-role" = "agent"
  })
}

resource "aws_vpc_security_group_ingress_rule" "agent_self" {
  for_each = local.has_agent_pools ? local.worker_ports : {}

  security_group_id            = aws_security_group.agent[0].id
  referenced_security_group_id = aws_security_group.agent[0].id
  ip_protocol                  = each.value.protocol
  from_port                    = each.value.from_port
  to_port                      = each.value.to_port
  description                  = "${each.key} from worker (self)"

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-worker-self-${each.key}"
    "elemental-role" = "agent"
  })
}

resource "aws_vpc_security_group_ingress_rule" "agent_from_control_plane" {
  for_each = local.has_agent_pools ? local.worker_ports : {}

  security_group_id            = aws_security_group.agent[0].id
  referenced_security_group_id = aws_security_group.control_plane.id
  ip_protocol                  = each.value.protocol
  from_port                    = each.value.from_port
  to_port                      = each.value.to_port
  description                  = "${each.key} from control_plane"

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-worker-from-control-plane-${each.key}"
    "elemental-role" = "agent"
  })
}

resource "aws_vpc_security_group_ingress_rule" "agent_ssh_from_jumphost" {
  count = local.has_agent_pools ? 1 : 0

  security_group_id            = aws_security_group.agent[0].id
  referenced_security_group_id = aws_security_group.jumphost.id
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  description                  = "ssh from jumphost"

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-worker-ssh-from-jumphost"
    "elemental-role" = "agent"
  })
}

resource "aws_vpc_security_group_egress_rule" "agent_all" {
  count = local.has_agent_pools ? 1 : 0

  security_group_id = aws_security_group.agent[0].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "unrestricted egress"

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-worker-egress-all"
    "elemental-role" = "agent"
  })
}
