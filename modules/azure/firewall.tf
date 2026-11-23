# Network security groups on the NICs carry every inbound rule; the subnets have
# none, so an existing network is not touched. Each group ends with a deny-all
# rule: the platform's default rules would otherwise allow every flow inside the
# virtual network. The jumphost is the only SSH entry. Nodes are grouped by
# application security groups, so etcd and the API are reachable from the right roles only.

module "rke2_ports" {
  source = "../rke2-ports"

  ingress_controller = var.ingress_controller
}

locals {
  nsg_names = ["jumphost", "control_plane", "agent"]

  nsg_roles = {
    jumphost      = "jumphost"
    control_plane = "control_plane"
    agent         = "agent"
  }

  api_ports     = [for k, v in module.rke2_ports.lb_api : v.from]
  ingress_ports = [for k, v in module.rke2_ports.lb_ingress : v.from]
  # The load balancer probes the NIC address from the AzureLoadBalancer service tag.
  probe_ports = distinct(concat([6443], [for k, h in module.rke2_ports.lb_ingress_health : h.port]))

  # api_cidrs and ingress_cidrs filter here (the frontend keeps the client source);
  # nodes may reach the frontend through the NAT gateway, so local.nat_cidrs are clients too.

  asg_both = [azurerm_application_security_group.this["control_plane"].id, azurerm_application_security_group.this["agent"].id]
  asg_cp   = [azurerm_application_security_group.this["control_plane"].id]

  # Node ports between cluster members; etcd between control planes only.
  node_ports = module.rke2_ports.worker

  # Rule name -> protocol, port range and one kind of source: CIDR list, service
  # tag or application security groups. Priority follows the sorted names.
  ssh_from_jumphost = { ssh = { protocol = "Tcp", port = "22", prefixes = [local.public_subnet_cidr], tag = null, asgs = null } }

  node_rules = {
    for k, v in local.node_ports : "nodes-${k}" => {
      protocol = title(v.protocol), port = v.from == v.to ? tostring(v.from) : "${v.from}-${v.to}", prefixes = null, tag = null, asgs = local.asg_both
    }
  }

  nsg_specs = {
    jumphost = {
      ssh = { protocol = "Tcp", port = "22", prefixes = var.admin_cidrs, tag = null, asgs = null }
    }

    control_plane = merge(
      local.ssh_from_jumphost,
      local.node_rules,
      { for p in local.probe_ports : "lb-probe-${p}" => { protocol = "Tcp", port = tostring(p), prefixes = null, tag = "AzureLoadBalancer", asgs = null } },
      { for p in local.api_ports : "client-${p}" => {
        protocol = "Tcp", port = tostring(p), prefixes = distinct(concat(p == 6443 ? var.api_cidrs : [], local.nat_cidrs)), tag = null, asgs = null
      } },
      { for p in local.ingress_ports : "client-${p}" => {
        protocol = "Tcp", port = tostring(p), prefixes = distinct(concat(var.ingress_cidrs, local.nat_cidrs)), tag = null, asgs = null
      } },
      { for p in local.api_ports : "nodes-${p}" => { protocol = "Tcp", port = tostring(p), prefixes = null, tag = null, asgs = local.asg_both } },
      { etcd = {
        protocol = "Tcp", port = "${module.rke2_ports.control_plane["etcd"].from}-${module.rke2_ports.control_plane["etcd"].to}", prefixes = null, tag = null, asgs = local.asg_cp
      } },
    )

    agent = merge(local.ssh_from_jumphost, local.node_rules)
  }

  rule_base = {
    access                                     = "Allow"
    description                                = null
    destination_address_prefix                 = "*"
    destination_address_prefixes               = null
    destination_application_security_group_ids = null
    destination_port_range                     = null
    destination_port_ranges                    = null
    direction                                  = "Inbound"
    name                                       = null
    priority                                   = null
    protocol                                   = null
    source_address_prefix                      = null
    source_address_prefixes                    = null
    source_application_security_group_ids      = null
    source_port_range                          = "*"
    source_port_ranges                         = null
  }

  nsg_rules = {
    for n, specs in local.nsg_specs : n => concat(
      [
        for i, k in sort(keys(specs)) : merge(local.rule_base, {
          name                                  = k
          description                           = k
          priority                              = 100 + i
          protocol                              = specs[k].protocol
          destination_port_range                = specs[k].port
          source_address_prefix                 = specs[k].tag
          source_address_prefixes               = specs[k].prefixes
          source_application_security_group_ids = specs[k].asgs
        })
      ],
      [merge(local.rule_base, {
        name                   = "deny-all-inbound"
        description            = "deny-all-inbound"
        priority               = 4096
        access                 = "Deny"
        protocol               = "*"
        destination_port_range = "*"
        source_address_prefix  = "*"
      })],
    )
  }
}

resource "azurerm_application_security_group" "this" {
  for_each = toset(["control_plane", "agent"])

  depends_on = [terraform_data.input_checks]

  name                = "${var.cluster_name}-${replace(each.key, "_", "-")}"
  location            = local.region
  resource_group_name = local.resource_group_name
  tags                = merge(local.labels, { "elemental-role" = local.nsg_roles[each.key] })
}

resource "azurerm_network_security_group" "this" {
  for_each = toset(local.nsg_names)

  depends_on = [terraform_data.input_checks]

  name                = "${var.cluster_name}-${replace(each.key, "_", "-")}"
  location            = local.region
  resource_group_name = local.resource_group_name
  security_rule       = local.nsg_rules[each.key]
  tags                = merge(local.labels, { "elemental-role" = local.nsg_roles[each.key] })
}
