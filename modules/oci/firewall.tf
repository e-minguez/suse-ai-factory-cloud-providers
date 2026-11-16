# Network security groups carry every inbound rule; the VCN default security
# list allows egress and ICMP 3/4 only. The jumphost is the only SSH entry.

module "rke2_ports" {
  source = "../rke2-ports"

  ingress_controller = var.ingress_controller
}

locals {
  nsg_names = ["jumphost", "nlb", "control_plane", "agent"]

  nsg_roles = {
    jumphost      = "jumphost"
    nlb           = "lb"
    control_plane = "control_plane"
    agent         = "agent"
  }

  nsg_ids = {
    jumphost      = oci_core_network_security_group.this["jumphost"].id
    nlb           = oci_core_network_security_group.this["nlb"].id
    control_plane = oci_core_network_security_group.this["control_plane"].id
    agent         = oci_core_network_security_group.this["agent"].id
  }

  api_ports     = [for k, v in module.rke2_ports.lb_api : v.from]
  ingress_ports = [for k, v in module.rke2_ports.lb_ingress : v.from]
  # Listener traffic (no listener preserves the source) and health checks come
  # from the NLB's address in the public subnet.
  nlb_backend_ports = distinct(concat(
    local.api_ports,
    local.ingress_ports,
    [for k, h in module.rke2_ports.lb_ingress_health : h.port],
  ))

  # The NLB's own NSG filters api_cidrs and ingress_cidrs (loadbalancer.tf). Nodes
  # reach the public address through the NAT gateway, so its address is a client.
  nat_cidr = local.nat_ip == null ? "0.0.0.0/32" : "${local.nat_ip}/32"

  # Clients of the NLB listeners: port -> label -> CIDR. The label is the rule
  # key, so it must be known at plan time (the NAT address is not).
  client_cidrs = merge(
    { for p in local.api_ports : tostring(p) => merge(
      p == 6443 ? { for c in var.api_cidrs : c => c } : {},
      { nat = local.nat_cidr },
    ) },
    { for p in local.ingress_ports : tostring(p) => merge({ for c in var.ingress_cidrs : c => c }, { nat = local.nat_cidr }) },
  )

  # Node ports between cluster members; etcd between control planes only.
  node_ports = module.rke2_ports.worker

  client_rules = merge([
    for p, cidrs in local.client_cidrs : { for label, c in cidrs : "nlb-client-${p}-${label}" => {
      nsg = "nlb", protocol = "tcp", from = tonumber(p), to = tonumber(p), source = c, source_type = "CIDR_BLOCK"
    } }
  ]...)

  # Each rule: group it protects, protocol, port range, and one source.
  nsg_rules = merge(
    { for c in var.admin_cidrs : "jumphost-ssh-${c}" => {
      nsg = "jumphost", protocol = "tcp", from = 22, to = 22, source = c, source_type = "CIDR_BLOCK"
    } },
    local.client_rules,
    { for p in local.nlb_backend_ports : "control_plane-nlb-${p}" => {
      nsg = "control_plane", protocol = "tcp", from = p, to = p, source = local.public_subnet_cidr, source_type = "CIDR_BLOCK"
    } },
    { for pair in setproduct(local.api_ports, ["control_plane", "agent"]) : "control_plane-api-${pair[0]}-${pair[1]}" => {
      nsg = "control_plane", protocol = "tcp", from = pair[0], to = pair[0], source = local.nsg_ids[pair[1]], source_type = "NETWORK_SECURITY_GROUP"
    } },
    { for pair in setproduct(keys(local.node_ports), ["control_plane", "agent"], ["control_plane", "agent"]) : "${pair[1]}-${pair[0]}-from-${pair[2]}" => {
      nsg    = pair[1], protocol = local.node_ports[pair[0]].protocol, from = local.node_ports[pair[0]].from, to = local.node_ports[pair[0]].to,
      source = local.nsg_ids[pair[2]], source_type = "NETWORK_SECURITY_GROUP"
    } },
    { "control_plane-etcd" = {
      nsg    = "control_plane", protocol = "tcp", from = module.rke2_ports.control_plane["etcd"].from, to = module.rke2_ports.control_plane["etcd"].to,
      source = local.nsg_ids["control_plane"], source_type = "NETWORK_SECURITY_GROUP"
    } },
    { for t in ["control_plane", "agent"] : "${t}-ssh" => {
      nsg = t, protocol = "tcp", from = 22, to = 22, source = local.nsg_ids["jumphost"], source_type = "NETWORK_SECURITY_GROUP"
    } },
  )
}

resource "oci_core_network_security_group" "this" {
  for_each = toset(local.nsg_names)

  depends_on = [terraform_data.input_checks]

  compartment_id = var.oci_compartment_ocid
  vcn_id         = local.vcn_id
  display_name   = "${var.cluster_name}-${replace(each.key, "_", "-")}"
  freeform_tags  = merge(local.labels, { "elemental-role" = local.nsg_roles[each.key] })
}

resource "oci_core_network_security_group_security_rule" "this" {
  for_each = local.nsg_rules

  network_security_group_id = local.nsg_ids[each.value.nsg]
  direction                 = "INGRESS"
  protocol                  = each.value.protocol == "tcp" ? "6" : "17"
  source                    = each.value.source
  source_type               = each.value.source_type
  description               = each.key

  dynamic "tcp_options" {
    for_each = each.value.protocol == "tcp" ? [1] : []

    content {
      destination_port_range {
        min = each.value.from
        max = each.value.to
      }
    }
  }

  dynamic "udp_options" {
    for_each = each.value.protocol == "udp" ? [1] : []

    content {
      destination_port_range {
        min = each.value.from
        max = each.value.to
      }
    }
  }
}
