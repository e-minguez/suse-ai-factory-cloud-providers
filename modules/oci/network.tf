# VCN with a public subnet (jumphost, NLB) and a private subnet (nodes, no
# public IP). Subnets are regional: they span every availability domain.
# Access is controlled by NSGs (firewall.tf); the VCN default security list
# opens only ICMP "fragmentation needed" inbound. With vpc_id the module creates none of this and reads
# the existing VCN, subnets, route tables and NAT gateway instead.

# Plan-time input checks; the VCN gates everything else.
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
      condition     = length(local.shape_errors) == 0
      error_message = "Invalid instance types: ${join("; ", local.shape_errors)}."
    }

    precondition {
      condition     = length(setsubtract(local.zone_set, keys(local.ad_names))) == 0
      error_message = "zones ${jsonencode(sort(setsubtract(local.zone_set, keys(local.ad_names))))} do not exist in ${local.region}: the availability domains are ${jsonencode(sort(keys(local.ad_names)))} (lowercase short names)."
    }

    precondition {
      condition     = !local.create_network || (local.vpc_prefix >= 16 && local.vpc_prefix <= 24)
      error_message = "vpc_cidr must be a /16 to /24: it is split into a public and a private subnet."
    }

    precondition {
      condition     = local.vpc_mtu <= 9000
      error_message = "vpc_mtu must be at most 9000: that is the largest frame inside a VCN."
    }

    precondition {
      condition     = alltrue([for k, p in local.agent_pools : p.kind == "vm"])
      error_message = "gpu_pools and worker_pools support kind = \"vm\" only: bare metal shapes cannot boot imported images."
    }

    precondition {
      condition     = alltrue([for k, p in local.agent_pools : p.zone == null || contains(local.zone_set, p.zone)])
      error_message = "A pool zone must be one of the cluster zones: ${jsonencode(local.zones)}."
    }

    precondition {
      condition     = var.image_id == null || can(regex("^ocid1\\.image\\.", var.image_id))
      error_message = "image_id must be an image OCID (ocid1.image...)."
    }

    precondition {
      condition     = !anytrue([for c in ["10.42.0.0/16", "10.43.0.0/16"] : local.cidr_overlaps[c]])
      error_message = "vpc_cidr ${local.vpc_cidr} overlaps the RKE2 default cluster-cidr 10.42.0.0/16 or service-cidr 10.43.0.0/16."
    }

    # Existing network (vpc_id): every check passes trivially when the module creates it.
    precondition {
      condition     = local.create_network || contains(try(data.oci_core_vcn.existing[0].cidr_blocks, []), local.vpc_cidr)
      error_message = "vpc_cidr ${local.vpc_cidr} is not a CIDR block of VCN ${coalesce(var.vpc_id, "-")} (${join(", ", try(data.oci_core_vcn.existing[0].cidr_blocks, []))}): leave vpc_cidr null or set one of them."
    }

    precondition {
      condition     = local.create_network || alltrue([for k, s in local.existing_subnets : s.vcn_id == var.vpc_id])
      error_message = "public_subnet_id and private_subnet_id must be subnets of vpc_id ${coalesce(var.vpc_id, "-")}."
    }

    precondition {
      condition     = local.create_network || alltrue([for k, s in local.existing_subnets : try(s.availability_domain, null) == null || try(s.availability_domain, "") == ""])
      error_message = "public_subnet_id and private_subnet_id must be regional subnets: nodes spread over availability domains."
    }

    precondition {
      condition     = local.create_network || alltrue([for k, s in local.existing_subnets : local.subnet_in_vpc[k]])
      error_message = "The subnets (${join(", ", compact([local.public_subnet_cidr, local.private_subnet_cidr]))}) must lie inside vpc_cidr ${local.vpc_cidr}."
    }

    precondition {
      condition     = local.create_network || !try(data.oci_core_subnet.public[0].prohibit_public_ip_on_vnic, true)
      error_message = "public_subnet_id must allow public IPs (prohibit_public_ip_on_vnic = false): the jumphost has one."
    }

    precondition {
      condition     = local.create_network || startswith(coalesce(local.default_route["public"], "-"), "ocid1.internetgateway.")
      error_message = "public_subnet_id must route 0.0.0.0/0 to an internet gateway (route table ${try(data.oci_core_subnet.public[0].route_table_id, "-")}; it must be in the VCN compartment)."
    }

    precondition {
      condition     = local.create_network || (startswith(coalesce(local.default_route["private"], "-"), "ocid1.natgateway.") && local.existing_nat_ip != null)
      error_message = "private_subnet_id must route 0.0.0.0/0 to a NAT gateway in the VCN compartment (route table ${try(data.oci_core_subnet.private[0].route_table_id, "-")}): nodes reach the load balancer's public address through it."
    }
  }
}

# Existing network (vpc_id). Route tables and NAT gateways are looked up in the
# VCN compartment.
data "oci_core_vcn" "existing" {
  count  = local.create_network ? 0 : 1
  vcn_id = var.vpc_id
}

data "oci_core_subnet" "public" {
  count     = local.create_network ? 0 : 1
  subnet_id = var.public_subnet_id
}

data "oci_core_subnet" "private" {
  count     = local.create_network ? 0 : 1
  subnet_id = var.private_subnet_id
}

data "oci_core_route_tables" "existing" {
  count          = local.create_network ? 0 : 1
  compartment_id = data.oci_core_vcn.existing[0].compartment_id
  vcn_id         = var.vpc_id
}

data "oci_core_nat_gateways" "existing" {
  count          = local.create_network ? 0 : 1
  compartment_id = data.oci_core_vcn.existing[0].compartment_id
  vcn_id         = var.vpc_id
}

locals {
  create_network = var.vpc_id == null

  existing_subnets = local.create_network ? {} : {
    public  = data.oci_core_subnet.public[0]
    private = data.oci_core_subnet.private[0]
  }
  route_tables = { for rt in try(data.oci_core_route_tables.existing[0].route_tables, []) : rt.id => rt }
  # Subnet -> target of its 0.0.0.0/0 route (null when absent or unreadable).
  default_route = { for k in ["public", "private"] : k => try(one([
    for r in local.route_tables[local.existing_subnets[k].route_table_id].route_rules : r.network_entity_id
    if r.destination == "0.0.0.0/0"
  ]), null) }
  nat_ips = { for g in try(data.oci_core_nat_gateways.existing[0].nat_gateways, []) : g.id => g.nat_ip }

  vcn_id            = local.create_network ? oci_core_vcn.this[0].id : var.vpc_id
  public_subnet_id  = local.create_network ? oci_core_subnet.public[0].id : var.public_subnet_id
  private_subnet_id = local.create_network ? oci_core_subnet.private[0].id : var.private_subnet_id
  nat_gateway_id    = local.create_network ? oci_core_nat_gateway.this[0].id : local.default_route["private"]
  existing_nat_ip   = lookup(local.nat_ips, coalesce(local.default_route["private"], "-"), null)
  nat_ip            = local.create_network ? oci_core_nat_gateway.this[0].nat_ip : local.existing_nat_ip

  # Same network address at the shorter of the two prefixes means overlap or containment.
  cidr_overlaps = { for c in ["10.42.0.0/16", "10.43.0.0/16"] : c => (
    cidrhost(format("%s/%d", cidrhost(local.vpc_cidr, 0), min(local.vpc_prefix, 16)), 0) == cidrhost(format("%s/%d", cidrhost(c, 0), min(local.vpc_prefix, 16)), 0)
  ) }
  subnet_in_vpc = { for k, s in local.existing_subnets : k => (
    tonumber(split("/", s.cidr_block)[1]) >= local.vpc_prefix &&
    cidrhost(format("%s/%d", cidrhost(s.cidr_block, 0), local.vpc_prefix), 0) == cidrhost(local.vpc_cidr, 0)
  ) }
}

resource "oci_core_vcn" "this" {
  count = local.create_network ? 1 : 0

  depends_on = [terraform_data.input_checks]

  compartment_id = var.oci_compartment_ocid
  display_name   = "${var.cluster_name}-vcn"
  cidr_blocks    = [local.vpc_cidr]
  freeform_tags  = merge(local.labels, { "elemental-role" = "network" })
}

# Egress plus ICMP 3/4: the default list ships with SSH open to the internet.
resource "oci_core_default_security_list" "this" {
  count = local.create_network ? 1 : 0

  manage_default_resource_id = oci_core_vcn.this[0].default_security_list_id
  display_name               = "${var.cluster_name}-default"
  freeform_tags              = merge(local.labels, { "elemental-role" = "network" })

  egress_security_rules {
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
    description      = "all egress"
  }

  # Path MTU discovery: "fragmentation needed" from 1500-byte internet paths (VCN MTU 9000).
  ingress_security_rules {
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    protocol    = "1"
    description = "icmp fragmentation needed"

    icmp_options {
      type = 3
      code = 4
    }
  }
}

resource "oci_core_internet_gateway" "this" {
  count = local.create_network ? 1 : 0

  compartment_id = var.oci_compartment_ocid
  vcn_id         = oci_core_vcn.this[0].id
  display_name   = "${var.cluster_name}-igw"
  freeform_tags  = merge(local.labels, { "elemental-role" = "network" })
}

# Egress of the private subnet; its address is the cluster's egress IP.
resource "oci_core_nat_gateway" "this" {
  count = local.create_network ? 1 : 0

  compartment_id = var.oci_compartment_ocid
  vcn_id         = oci_core_vcn.this[0].id
  display_name   = "${var.cluster_name}-nat"
  freeform_tags  = merge(local.labels, { "elemental-role" = "network" })
}

resource "oci_core_route_table" "public" {
  count = local.create_network ? 1 : 0

  compartment_id = var.oci_compartment_ocid
  vcn_id         = oci_core_vcn.this[0].id
  display_name   = "${var.cluster_name}-public"
  freeform_tags  = merge(local.labels, { "elemental-role" = "network" })

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.this[0].id
  }
}

resource "oci_core_route_table" "private" {
  count = local.create_network ? 1 : 0

  compartment_id = var.oci_compartment_ocid
  vcn_id         = oci_core_vcn.this[0].id
  display_name   = "${var.cluster_name}-private"
  freeform_tags  = merge(local.labels, { "elemental-role" = "network" })

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.this[0].id
  }
}

resource "oci_core_subnet" "public" {
  count = local.create_network ? 1 : 0

  compartment_id             = var.oci_compartment_ocid
  vcn_id                     = oci_core_vcn.this[0].id
  display_name               = "${var.cluster_name}-public"
  cidr_block                 = local.public_subnet_cidr
  route_table_id             = oci_core_route_table.public[0].id
  prohibit_public_ip_on_vnic = false
  freeform_tags              = merge(local.labels, { "elemental-role" = "network" })

  depends_on = [oci_core_default_security_list.this]
}

resource "oci_core_subnet" "private" {
  count = local.create_network ? 1 : 0

  compartment_id             = var.oci_compartment_ocid
  vcn_id                     = oci_core_vcn.this[0].id
  display_name               = "${var.cluster_name}-private"
  cidr_block                 = local.private_subnet_cidr
  route_table_id             = oci_core_route_table.private[0].id
  prohibit_public_ip_on_vnic = true
  freeform_tags              = merge(local.labels, { "elemental-role" = "network" })

  depends_on = [oci_core_default_security_list.this]
}
