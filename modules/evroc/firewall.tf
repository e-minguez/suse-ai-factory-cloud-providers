# Every node (jumphost, builders, control plane, agents) sits behind one of the groups below.

module "rke2_ports" {
  source = "../rke2-ports"

  ingress_controller = var.ingress_controller
}

# --- shared rule fragments ---
# Rules are maps of attributes rendered by one `dynamic "rule"` per direction.

locals {
  # Port 22 from admin_cidrs on every node group.
  admin_ssh_rules = {
    for cidr in var.admin_cidrs :
    "ssh-${replace(cidr, "/", "_")}" => {
      protocol  = "TCP"
      port      = 22
      end_port  = null
      remote_ip = cidr
    }
  }

  # SSH from the jumphost's /32 to control-plane and agent nodes. Unknown until
  # the jumphost exists, but a rule value, not a key, so the rule set stays
  # plan-known. Nodes without public IPs need it (admin_cidrs never matches a VPC source).
  jumphost_ssh_rule = {
    "ssh-jumphost" = {
      protocol  = "TCP"
      port      = 22
      end_port  = null
      remote_ip = "${evroc_virtual_machine.jumphost.private_ipv4_address}/32"
    }
  }

  # Build-status relay (templates/status-relay.py): read from admin_cidrs, publish
  # from the VPC (the relay accepts PUT only from vpc_cidr). Dropped on pass 2.
  status_relay_rules = var.image_ready ? {} : merge(
    {
      for cidr in var.admin_cidrs :
      "status-${replace(cidr, "/", "_")}" => {
        protocol  = "TCP"
        port      = local.status_relay_port
        end_port  = null
        remote_ip = cidr
      }
    },
    {
      "status-vpc" = {
        protocol  = "TCP"
        port      = local.status_relay_port
        end_port  = null
        remote_ip = local.vpc_cidr
      }
    },
  )

  # Egress is unrestricted on every group.
  egress_all_rules = {
    tcp = { protocol = "TCP", port = 0, end_port = null, remote_ip = "0.0.0.0/0" }
    udp = { protocol = "UDP", port = 0, end_port = null, remote_ip = "0.0.0.0/0" }
  }

  # Node-to-node ports cite vpc_cidr, not a group: groups cannot reference themselves
  # and mutual references cycle. Excludes LB-facing and ingress ports (own sources below).
  intra_cluster_rules = {
    for k, v in module.rke2_ports.control_plane : k => {
      protocol  = upper(v.protocol)
      port      = v.from
      end_port  = v.to == v.from ? null : v.to
      remote_ip = local.vpc_cidr
    } if !contains(keys(module.rke2_ports.lb_api), k) && !contains(keys(module.rke2_ports.control_plane_ingress), k)
  }

  worker_intra_cluster_rules = {
    for k, v in module.rke2_ports.worker : k => {
      protocol  = upper(v.protocol)
      port      = v.from
      end_port  = v.to == v.from ? null : v.to
      remote_ip = local.vpc_cidr
    }
  }
}

# --- jumphost ---
# The public admin entrypoint: admin_cidrs SSH plus the status relay during a build.
resource "evroc_security_group" "jumphost" {
  name        = "${var.cluster_name}-jumphost"
  vpc_ref     = evroc_vpc.this.fqid
  project     = var.project
  region      = var.region
  user_labels = merge(local.common_labels, { "elemental-role" = "jumphost" })

  dynamic "rule" {
    for_each = merge(local.admin_ssh_rules, local.status_relay_rules)
    content {
      name      = rule.key
      direction = "Ingress"
      protocol  = rule.value.protocol
      port      = rule.value.port
      end_port  = rule.value.end_port
      remote_ip = rule.value.remote_ip
    }
  }

  dynamic "rule" {
    for_each = local.egress_all_rules
    content {
      name      = "egress-${rule.key}"
      direction = "Egress"
      protocol  = rule.value.protocol
      port      = rule.value.port
      end_port  = rule.value.end_port
      remote_ip = rule.value.remote_ip
    }
  }
}

# --- builders ---
# SSH from the jumphost only (no public IP, so no admin_ssh_rules). Separate from
# the jumphost group to avoid a dependency cycle (build.tf).
resource "evroc_security_group" "builder" {
  count = length(local.builder_zones) > 0 ? 1 : 0

  name        = "${var.cluster_name}-builder"
  vpc_ref     = evroc_vpc.this.fqid
  project     = var.project
  region      = var.region
  user_labels = merge(local.common_labels, { "elemental-role" = "builder" })

  rule {
    name      = "ssh-jumphost"
    direction = "Ingress"
    protocol  = "TCP"
    port      = 22
    end_port  = null
    remote_ip = "${evroc_virtual_machine.jumphost.private_ipv4_address}/32"
  }

  dynamic "rule" {
    for_each = local.egress_all_rules
    content {
      name      = "egress-${rule.key}"
      direction = "Egress"
      protocol  = rule.value.protocol
      port      = rule.value.port
      end_port  = rule.value.end_port
      remote_ip = rule.value.remote_ip
    }
  }
}

# --- control plane ---
locals {
  # The load balancer keeps the client address: 6443 from api_cidrs and the VPC
  # (nodes dial servers directly), 9345 from anywhere (nodes without a public IP
  # join from undisclosed egress addresses).
  control_plane_lb_rules = merge(
    {
      for cidr in distinct(concat(var.api_cidrs, [local.vpc_cidr])) : "kube_api-${replace(cidr, "/", "_")}" => {
        protocol  = upper(module.rke2_ports.lb_api.kube_api.protocol)
        port      = module.rke2_ports.lb_api.kube_api.from
        end_port  = null
        remote_ip = cidr
      }
    },
    {
      supervisor = {
        protocol  = upper(module.rke2_ports.lb_api.supervisor.protocol)
        port      = module.rke2_ports.lb_api.supervisor.from
        end_port  = null
        remote_ip = "0.0.0.0/0"
      }
    },
  )

  # Ingress ports open to ingress_cidrs, plus Traefik's ping port to the world for
  # the LB health check (loadbalancer.tf); with ingress-nginx ingress_cidrs must
  # cover the health checker.
  control_plane_ingress_rules = merge(
    {
      for pair in setproduct(keys(module.rke2_ports.lb_ingress), var.ingress_cidrs) :
      "${pair[0]}-${replace(pair[1], "/", "_")}" => {
        protocol  = upper(module.rke2_ports.lb_ingress[pair[0]].protocol)
        port      = module.rke2_ports.lb_ingress[pair[0]].from
        end_port  = null
        remote_ip = pair[1]
      }
    },
    {
      for k, v in module.rke2_ports.control_plane_ingress : "ingress-lb-health-check" => {
        protocol  = upper(v.protocol)
        port      = v.from
        end_port  = null
        remote_ip = "0.0.0.0/0"
      } if k == "ingress_ping"
    },
  )

  control_plane_ingress_rules_all = merge(
    local.admin_ssh_rules,
    local.jumphost_ssh_rule,
    local.control_plane_lb_rules,
    local.intra_cluster_rules,
    local.control_plane_ingress_rules,
  )
}

resource "evroc_security_group" "control_plane" {
  name        = "${var.cluster_name}-control-plane"
  vpc_ref     = evroc_vpc.this.fqid
  project     = var.project
  region      = var.region
  user_labels = merge(local.common_labels, { "elemental-role" = "control_plane" })

  dynamic "rule" {
    for_each = local.control_plane_ingress_rules_all
    content {
      name      = rule.key
      direction = "Ingress"
      protocol  = rule.value.protocol
      port      = rule.value.port
      end_port  = rule.value.end_port
      remote_ip = rule.value.remote_ip
    }
  }

  dynamic "rule" {
    for_each = local.egress_all_rules
    content {
      name      = "egress-${rule.key}"
      direction = "Egress"
      protocol  = rule.value.protocol
      port      = rule.value.port
      end_port  = rule.value.end_port
      remote_ip = rule.value.remote_ip
    }
  }
}

# --- worker ---
# Serves worker_pools and gpu_pools; created only when either is non-empty.
locals {
  worker_ingress_rules_all = merge(
    local.admin_ssh_rules,
    local.jumphost_ssh_rule,
    local.worker_intra_cluster_rules,
  )
}

resource "evroc_security_group" "agent" {
  count = length(local.agent_pools) > 0 ? 1 : 0

  name    = "${var.cluster_name}-agent"
  vpc_ref = evroc_vpc.this.fqid
  project = var.project
  region  = var.region

  # No `pool` label: one group serves every pool and role.
  user_labels = merge(local.common_labels, { "elemental-role" = "agent" })

  dynamic "rule" {
    for_each = local.worker_ingress_rules_all
    content {
      name      = rule.key
      direction = "Ingress"
      protocol  = rule.value.protocol
      port      = rule.value.port
      end_port  = rule.value.end_port
      remote_ip = rule.value.remote_ip
    }
  }

  dynamic "rule" {
    for_each = local.egress_all_rules
    content {
      name      = "egress-${rule.key}"
      direction = "Egress"
      protocol  = rule.value.protocol
      port      = rule.value.port
      end_port  = rule.value.end_port
      remote_ip = rule.value.remote_ip
    }
  }
}
