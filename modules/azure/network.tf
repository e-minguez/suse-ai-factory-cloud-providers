# Resource group, virtual network with a public subnet (jumphost) and a private
# subnet (nodes, no public IP), and a NAT gateway for the private subnet.
# Access is controlled by NSGs on the NICs (firewall.tf), never on the subnets.
# With vpc_id the module creates none of the network and reads the existing
# virtual network, subnets and NAT gateway instead.

# Plan-time input checks; everything that consumes quota waits for them.
resource "terraform_data" "input_checks" {
  lifecycle {
    precondition {
      condition     = !var.control_plane_public_ip
      error_message = "control_plane_public_ip must be false: nodes sit in the private subnet and reach the internet through the NAT gateway."
    }

    precondition {
      condition     = alltrue([for k, p in local.agent_pools : !p.public_ip])
      error_message = "worker_pools and gpu_pools public_ip must be false: nodes sit in the private subnet."
    }

    precondition {
      condition     = alltrue([for k, p in local.agent_pools : p.placement == null])
      error_message = "worker_pools and gpu_pools placement must be null: placement groups are not supported."
    }

    precondition {
      condition     = alltrue([for k, p in local.agent_pools : p.kind == "vm"])
      error_message = "gpu_pools and worker_pools support kind = \"vm\" only."
    }

    precondition {
      condition     = length(local.size_errors) == 0
      error_message = "Invalid instance types: ${join("; ", local.size_errors)}."
    }

    precondition {
      condition     = can(regex("^[^:]+:[^:]+:[^:]+:[^:]+$", local.jumphost_image))
      error_message = "jumphost_image must be a marketplace URN publisher:offer:sku:version (version may be \"latest\")."
    }

    precondition {
      condition     = !contains(local.reserved_usernames, lower(var.node_username)) && !contains(local.reserved_usernames, lower(local.jumphost_admin_user))
      error_message = "node_username and jumphost_username must not be one of the names Azure reserves for the VM admin account (${join(", ", local.reserved_usernames)})."
    }

    precondition {
      condition     = alltrue([for k, p in local.agent_pools : p.zone == null || contains(local.zones, p.zone)])
      error_message = "A pool zone must be one of the cluster zones: ${jsonencode(local.zones)}."
    }

    precondition {
      condition     = !local.create_network || (local.vpc_prefix >= 16 && local.vpc_prefix <= 24)
      error_message = "vpc_cidr must be a /16 to /24: it is split into a public and a private subnet."
    }

    precondition {
      condition     = local.vpc_mtu <= 1500
      error_message = "vpc_mtu must be at most 1500: that is the frame size of a virtual network unless its MTU is raised, which this module does not do."
    }

    precondition {
      condition     = var.image_id == null || can(regex("(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.Compute/galleries/[^/]+/images/[^/]+/versions/[^/]+$", var.image_id))
      error_message = "image_id must be an Azure Compute Gallery image version ID (/subscriptions/.../galleries/<gallery>/images/<image>/versions/<version>)."
    }

    precondition {
      condition     = !anytrue([for c in ["10.42.0.0/16", "10.43.0.0/16"] : local.cidr_overlaps[c]])
      error_message = "vpc_cidr ${local.vpc_cidr} overlaps the RKE2 default cluster-cidr 10.42.0.0/16 or service-cidr 10.43.0.0/16."
    }

    # Existing network (vpc_id): every check passes trivially when the module creates it.
    precondition {
      condition     = local.create_network || lower(try(data.azurerm_virtual_network.existing[0].location, "")) == local.region
      error_message = "The virtual network ${coalesce(var.vpc_id, "-")} is in ${try(data.azurerm_virtual_network.existing[0].location, "-")}, not in region ${local.region}."
    }

    precondition {
      condition     = local.create_network || contains(try(data.azurerm_virtual_network.existing[0].address_space, []), local.vpc_cidr)
      error_message = "vpc_cidr ${local.vpc_cidr} is not an address space of ${coalesce(var.vpc_id, "-")} (${join(", ", try(data.azurerm_virtual_network.existing[0].address_space, []))}): leave vpc_cidr null or set one of them."
    }

    precondition {
      condition     = local.create_network || lower(local.parsed_ids["vnet"].sub) == lower(var.azure_subscription_id)
      error_message = "vpc_id ${coalesce(var.vpc_id, "-")} is in another subscription than azure_subscription_id: the module reads and attaches the network in one subscription."
    }

    precondition {
      condition     = local.create_network || alltrue([for k, id in local.existing_ids : k == "vnet" || startswith(lower(id), "${lower(var.vpc_id)}/subnets/")])
      error_message = "public_subnet_id and private_subnet_id must be subnets of vpc_id ${coalesce(var.vpc_id, "-")}."
    }

    precondition {
      condition     = local.create_network || alltrue([for k, s in local.existing_subnets : local.subnet_in_vpc[k]])
      error_message = "The subnets (${join(", ", compact([local.public_subnet_cidr, local.private_subnet_cidr]))}) must lie inside vpc_cidr ${local.vpc_cidr}."
    }

    precondition {
      condition     = local.create_network || length(local.existing_nat_ips) + length(local.existing_nat_prefixes) > 0
      error_message = "private_subnet_id must have a NAT gateway with a public IP address or prefix (subnet ${coalesce(var.private_subnet_id, "-")}): nodes reach the load balancer's public address through it, and its addresses are the cluster egress IPs."
    }
  }
}

locals {
  create_network = var.vpc_id == null

  # (?P<name>) captures; the subnet group is empty for the virtual network ID.
  id_pattern   = "(?i)^/subscriptions/(?P<sub>[^/]+)/resourceGroups/(?P<rg>[^/]+)/providers/Microsoft\\.Network/virtualNetworks/(?P<vnet>[^/]+)(?:/subnets/(?P<subnet>[^/]+))?$"
  existing_ids = local.create_network ? {} : { vnet = var.vpc_id, public = var.public_subnet_id, private = var.private_subnet_id }
  parsed_ids   = { for k, id in local.existing_ids : k => regex(local.id_pattern, id) }
}

# Existing network (vpc_id). Subnet details the azurerm data source lacks come from ARM.
data "azurerm_virtual_network" "existing" {
  count = local.create_network ? 0 : 1

  name                = local.parsed_ids["vnet"].vnet
  resource_group_name = local.parsed_ids["vnet"].rg
}

data "azurerm_subnet" "existing" {
  for_each = { for k, p in local.parsed_ids : k => p if k != "vnet" }

  name                 = each.value.subnet
  virtual_network_name = each.value.vnet
  resource_group_name  = each.value.rg
}

data "azapi_resource" "existing_subnet" {
  for_each = { for k, id in local.existing_ids : k => id if k != "vnet" }

  type                   = "Microsoft.Network/virtualNetworks/subnets@2024-05-01"
  resource_id            = each.value
  response_export_values = ["properties.natGateway.id"]
}

locals {
  existing_subnets = {
    for k, s in data.azurerm_subnet.existing : k => {
      cidr   = try(s.address_prefixes[0], null)
      nat_id = try(data.azapi_resource.existing_subnet[k].output.properties.natGateway.id, null)
    }
  }
}

data "azapi_resource" "existing_nat" {
  count = try(local.existing_subnets["private"].nat_id, null) != null ? 1 : 0

  type                   = "Microsoft.Network/natGateways@2024-05-01"
  resource_id            = local.existing_subnets["private"].nat_id
  response_export_values = ["properties.publicIpAddresses", "properties.publicIpPrefixes"]
}

# Every address and prefix of the gateway is a source of cluster egress.
data "azapi_resource" "existing_nat_ips" {
  for_each = toset([for a in try(data.azapi_resource.existing_nat[0].output.properties.publicIpAddresses, []) : a.id])

  type                   = "Microsoft.Network/publicIPAddresses@2024-05-01"
  resource_id            = each.value
  response_export_values = ["properties.ipAddress"]
}

data "azapi_resource" "existing_nat_prefixes" {
  for_each = toset([for a in try(data.azapi_resource.existing_nat[0].output.properties.publicIpPrefixes, []) : a.id])

  type                   = "Microsoft.Network/publicIPPrefixes@2024-05-01"
  resource_id            = each.value
  response_export_values = ["properties.ipPrefix"]
}

locals {
  existing_nat_ips      = compact([for k, d in data.azapi_resource.existing_nat_ips : try(d.output.properties.ipAddress, null)])
  existing_nat_prefixes = compact([for k, d in data.azapi_resource.existing_nat_prefixes : try(d.output.properties.ipPrefix, null)])

  # Egress sources: addresses, then prefixes as CIDRs.
  nat_cidrs      = local.create_network ? ["${azurerm_public_ip.nat[0].ip_address}/32"] : concat([for a in local.existing_nat_ips : "${a}/32"], local.existing_nat_prefixes)
  egress_ips     = local.create_network ? [azurerm_public_ip.nat[0].ip_address] : concat(local.existing_nat_ips, local.existing_nat_prefixes)
  nat_gateway_id = local.create_network ? azurerm_nat_gateway.this[0].id : try(local.existing_subnets["private"].nat_id, null)

  virtual_network_id = local.create_network ? azurerm_virtual_network.this[0].id : var.vpc_id
  public_subnet_id   = local.create_network ? azurerm_subnet.public[0].id : var.public_subnet_id
  private_subnet_id  = local.create_network ? azurerm_subnet.private[0].id : var.private_subnet_id

  # Same network address at the shorter of the two prefixes means overlap or containment.
  cidr_overlaps = { for c in ["10.42.0.0/16", "10.43.0.0/16"] : c => (
    cidrhost(format("%s/%d", cidrhost(local.vpc_cidr, 0), min(local.vpc_prefix, 16)), 0) == cidrhost(format("%s/%d", cidrhost(c, 0), min(local.vpc_prefix, 16)), 0)
  ) }
  subnet_in_vpc = { for k, s in local.existing_subnets : k => (
    s.cidr != null &&
    tonumber(split("/", s.cidr)[1]) >= local.vpc_prefix &&
    cidrhost(format("%s/%d", cidrhost(s.cidr, 0), local.vpc_prefix), 0) == cidrhost(local.vpc_cidr, 0)
  ) }
}

# A resource group the module created is the one it deletes.
resource "azurerm_resource_group" "this" {
  count = var.resource_group_name == null ? 1 : 0

  depends_on = [terraform_data.limits_check]

  name     = var.cluster_name
  location = local.region
  tags     = merge(local.labels, { "elemental-role" = "network" })
}

data "azurerm_resource_group" "existing" {
  count = var.resource_group_name == null ? 0 : 1

  name = var.resource_group_name
}

locals {
  resource_group_name = var.resource_group_name == null ? azurerm_resource_group.this[0].name : data.azurerm_resource_group.existing[0].name
  resource_group_id   = var.resource_group_name == null ? azurerm_resource_group.this[0].id : data.azurerm_resource_group.existing[0].id
}

resource "azurerm_virtual_network" "this" {
  count = local.create_network ? 1 : 0

  depends_on = [terraform_data.input_checks]

  name                = var.cluster_name
  location            = local.region
  resource_group_name = local.resource_group_name
  address_space       = [local.vpc_cidr]
  tags                = merge(local.labels, { "elemental-role" = "network" })
}

# default_outbound_access_enabled = false: the platform default is going away, and
# every node has an explicit egress (the NAT gateway; the jumphost's public IP).
resource "azurerm_subnet" "public" {
  count = local.create_network ? 1 : 0

  name                            = "${var.cluster_name}-public"
  resource_group_name             = local.resource_group_name
  virtual_network_name            = azurerm_virtual_network.this[0].name
  address_prefixes                = [local.public_subnet_cidr]
  default_outbound_access_enabled = false
}

resource "azurerm_subnet" "private" {
  count = local.create_network ? 1 : 0

  name                            = "${var.cluster_name}-private"
  resource_group_name             = local.resource_group_name
  virtual_network_name            = azurerm_virtual_network.this[0].name
  address_prefixes                = [local.private_subnet_cidr]
  default_outbound_access_enabled = false
}

# Egress of the private subnet; its address is the cluster's egress IP.
resource "azurerm_public_ip" "nat" {
  count = local.create_network ? 1 : 0

  depends_on = [terraform_data.limits_check]

  name                = "${var.cluster_name}-nat"
  location            = local.region
  resource_group_name = local.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = null
  tags                = merge(local.labels, { "elemental-role" = "network" })

  lifecycle {
    ignore_changes = [zones]
  }
}

resource "azurerm_nat_gateway" "this" {
  count = local.create_network ? 1 : 0

  name                = "${var.cluster_name}-nat"
  location            = local.region
  resource_group_name = local.resource_group_name
  sku_name            = "Standard"
  tags                = merge(local.labels, { "elemental-role" = "network" })
}

resource "azurerm_nat_gateway_public_ip_association" "this" {
  count = local.create_network ? 1 : 0

  nat_gateway_id       = azurerm_nat_gateway.this[0].id
  public_ip_address_id = azurerm_public_ip.nat[0].id
}

resource "azurerm_subnet_nat_gateway_association" "private" {
  count = local.create_network ? 1 : 0

  subnet_id      = azurerm_subnet.private[0].id
  nat_gateway_id = azurerm_nat_gateway.this[0].id

  depends_on = [azurerm_nat_gateway_public_ip_association.this]
}
