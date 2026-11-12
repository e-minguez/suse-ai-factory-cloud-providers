# VPC, subnets, NAT egress and the S3 gateway endpoint. Subnets are indexed
# by zone: index i of every list is local.az_names[i].

# Local and Wavelength Zones are excluded: they do not carry the full instance catalogue.
data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "zone-type"
    values = ["availability-zone"]
  }

  lifecycle {
    precondition {
      condition     = var.region != null
      error_message = "region is required."
    }
  }
}

# Plan-time input checks. Kept off the VPC, which does not exist with vpc_id.
resource "terraform_data" "input_checks" {
  lifecycle {
    precondition {
      condition     = !var.control_plane_public_ip
      error_message = "control_plane_public_ip must be false: nodes sit in private subnets and reach the internet through the NAT gateway."
    }

    precondition {
      condition     = alltrue([for k, p in local.agent_pools : p.kind == "vm"])
      error_message = "Every worker_pools and gpu_pools kind must be \"vm\"."
    }

    precondition {
      condition     = alltrue([for k, p in local.agent_pools : !p.public_ip])
      error_message = "worker_pools and gpu_pools public_ip must be false: nodes sit in private subnets."
    }

    precondition {
      condition     = alltrue([for k, p in local.agent_pools : p.placement == null])
      error_message = "worker_pools and gpu_pools placement is not supported and must be null."
    }

    precondition {
      condition     = alltrue([for k, p in local.agent_pools : contains(local.zones, p.zone)])
      error_message = "Every worker_pools and gpu_pools zone must be one of the zones in use: ${join(", ", local.zones)}."
    }

    precondition {
      condition     = alltrue([for n in local.az_names : contains(data.aws_availability_zones.available.names, n)])
      error_message = "zones must be Availability Zones of region ${coalesce(var.region, "unset")} (Local and Wavelength Zones excluded). Available: ${join(", ", data.aws_availability_zones.available.names)}."
    }

    precondition {
      condition     = length(var.cluster_name) <= 21
      error_message = "cluster_name must be at most 21 characters: load balancer and target group names (cluster_name plus a suffix of up to 11 characters) are capped at 32."
    }

    precondition {
      condition     = alltrue([for k in keys(var.tags) : !startswith(k, "aws:")])
      error_message = "tags keys must not start with \"aws:\", a reserved prefix."
    }

  }
}

# DNS support and hostnames stay on for in-VPC name resolution. Not created
# with var.vpc_id.
resource "aws_vpc" "this" {
  count = var.vpc_id == null ? 1 : 0

  cidr_block           = local.vpc_cidr_new
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-vpc"
    "elemental-role" = "network"
  })
}

# Public subnets: the jumphost and the public NLB. Addresses are assigned
# explicitly, hence map_public_ip_on_launch = false.
resource "aws_subnet" "public" {
  count = var.vpc_id == null ? local.az_count : 0

  vpc_id                  = aws_vpc.this[0].id
  cidr_block              = local.public_subnet_cidrs[count.index]
  availability_zone       = local.az_names[count.index]
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-public-${local.az_names[count.index]}"
    "elemental-role" = "network"
  })
}

# Private subnets: control plane, worker and GPU nodes and the internal API NLB.
resource "aws_subnet" "private" {
  count = var.vpc_id == null ? local.az_count : 0

  vpc_id                  = aws_vpc.this[0].id
  cidr_block              = local.private_subnet_cidrs[count.index]
  availability_zone       = local.az_names[count.index]
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-private-${local.az_names[count.index]}"
    "elemental-role" = "network"
  })
}

resource "aws_internet_gateway" "this" {
  count = var.vpc_id == null ? 1 : 0

  vpc_id = aws_vpc.this[0].id

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-igw"
    "elemental-role" = "network"
  })
}

resource "aws_route_table" "public" {
  count = var.vpc_id == null ? 1 : 0

  vpc_id = aws_vpc.this[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this[0].id
  }

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-public"
    "elemental-role" = "network"
  })
}

resource "aws_route_table_association" "public" {
  count = var.vpc_id == null ? local.az_count : 0

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

# One NAT gateway, in the first public subnet, serves every private subnet.
# Losing it interrupts egress only; the API and ingress paths use the NLBs.
resource "aws_eip" "nat" {
  count = var.vpc_id == null ? 1 : 0

  domain = "vpc"

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-nat-0"
    "elemental-role" = "network"
  })
}

resource "aws_nat_gateway" "this" {
  count = var.vpc_id == null ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id

  # The gateway must be created after the internet gateway is attached.
  depends_on = [aws_internet_gateway.this]

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-nat-0"
    "elemental-role" = "network"
  })
}

resource "aws_route_table" "private" {
  count = var.vpc_id == null ? local.az_count : 0

  vpc_id = aws_vpc.this[0].id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[0].id
  }

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-private-${local.az_names[count.index]}"
    "elemental-role" = "network"
  })
}

resource "aws_route_table_association" "private" {
  count = var.vpc_id == null ? local.az_count : 0

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# Gateway endpoints have no hourly or per-GB charge; S3 traffic skips the NAT
# gateway. Not created with var.vpc_id: the module leaves existing route tables alone.
resource "aws_vpc_endpoint" "s3" {
  count = var.vpc_id == null ? 1 : 0

  vpc_id            = aws_vpc.this[0].id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-s3-endpoint"
    "elemental-role" = "network"
  })
}

moved {
  from = aws_vpc.this
  to   = aws_vpc.this[0]
}

moved {
  from = aws_internet_gateway.this
  to   = aws_internet_gateway.this[0]
}

moved {
  from = aws_route_table.public
  to   = aws_route_table.public[0]
}

moved {
  from = aws_eip.nat
  to   = aws_eip.nat[0]
}

moved {
  from = aws_nat_gateway.this
  to   = aws_nat_gateway.this[0]
}

moved {
  from = aws_vpc_endpoint.s3
  to   = aws_vpc_endpoint.s3[0]
}

# --- Existing VPC (var.vpc_id) ----------------------------------------------
#
# Read only: destroy leaves the VPC, subnets, gateways and route tables in place.
data "aws_vpc" "existing" {
  count = var.vpc_id != null ? 1 : 0

  id = var.vpc_id

  lifecycle {
    postcondition {
      condition     = var.vpc_cidr == null || self.cidr_block == var.vpc_cidr
      error_message = "vpc_cidr (${coalesce(var.vpc_cidr, "null")}) does not match the primary CIDR of ${var.vpc_id}, ${self.cidr_block}. Leave vpc_cidr null with vpc_id."
    }

    # Same rule as the vpc_cidr validation (variables-common.tf).
    postcondition {
      condition = !anytrue([
        for c in ["10.42.0.0/16", "10.43.0.0/16"] :
        cidrhost(format("%s/%d", cidrhost(self.cidr_block, 0), min(tonumber(split("/", self.cidr_block)[1]), 16)), 0) == cidrhost(format("%s/%d", cidrhost(c, 0), min(tonumber(split("/", self.cidr_block)[1]), 16)), 0)
      ])
      error_message = "The primary CIDR of ${var.vpc_id}, ${self.cidr_block}, overlaps the RKE2 default cluster-cidr 10.42.0.0/16 or service-cidr 10.43.0.0/16."
    }

    # Nodes reach the API through the internal NLB's DNS name.
    postcondition {
      condition     = self.enable_dns_support
      error_message = "${var.vpc_id} must have DNS support enabled: nodes resolve the internal API load balancer by name."
    }
  }
}

data "aws_subnet" "public" {
  for_each = var.vpc_id != null ? var.public_subnet_ids : {}

  id = each.value

  lifecycle {
    postcondition {
      condition     = self.vpc_id == var.vpc_id && self.availability_zone == "${var.region}${each.key}"
      error_message = "public_subnet_ids[\"${each.key}\"] = ${each.value} is in ${self.vpc_id}, ${self.availability_zone}; expected ${var.vpc_id}, ${var.region}${each.key}."
    }

    postcondition {
      condition     = local.existing_vpc_cidr == null || cidrhost(format("%s/%s", cidrhost(self.cidr_block, 0), split("/", local.existing_vpc_cidr)[1]), 0) == cidrhost(local.existing_vpc_cidr, 0)
      error_message = "Public subnet ${each.value} (${self.cidr_block}) is outside the VPC primary CIDR ${coalesce(local.existing_vpc_cidr, "-")}; the security groups admit only that range."
    }
  }
}

data "aws_subnet" "private" {
  for_each = var.vpc_id != null ? var.private_subnet_ids : {}

  id = each.value

  lifecycle {
    postcondition {
      condition     = self.vpc_id == var.vpc_id && self.availability_zone == "${var.region}${each.key}"
      error_message = "private_subnet_ids[\"${each.key}\"] = ${each.value} is in ${self.vpc_id}, ${self.availability_zone}; expected ${var.vpc_id}, ${var.region}${each.key}."
    }

    postcondition {
      condition     = local.existing_vpc_cidr == null || cidrhost(format("%s/%s", cidrhost(self.cidr_block, 0), split("/", local.existing_vpc_cidr)[1]), 0) == cidrhost(local.existing_vpc_cidr, 0)
      error_message = "Private subnet ${each.value} (${self.cidr_block}) is outside the VPC primary CIDR ${coalesce(local.existing_vpc_cidr, "-")}; the security groups admit only that range."
    }

    # Control planes take hosts 20+ of their zone's private subnet, the API VIP host 10.
    postcondition {
      condition     = can(cidrhost(self.cidr_block, local.node_ip_base_offset + length([for n in local.control_plane_nodes_raw : n if local.zones[n.az_index] == each.key])))
      error_message = "Private subnet ${each.value} (${self.cidr_block}) has no room for host 10 (API VIP) and hosts ${local.node_ip_base_offset}+ (one per control plane in zone ${each.key}). Use a larger subnet or fewer control planes per zone."
    }
  }
}

# Route tables of the existing subnets: the explicitly associated one, else the
# VPC main route table.
data "aws_route_table" "existing_main" {
  count = var.vpc_id != null ? 1 : 0

  vpc_id = var.vpc_id

  filter {
    name   = "association.main"
    values = ["true"]
  }
}

data "aws_route_tables" "public" {
  for_each = var.vpc_id != null ? var.public_subnet_ids : {}

  vpc_id = var.vpc_id

  filter {
    name   = "association.subnet-id"
    values = [each.value]
  }
}

data "aws_route_tables" "private" {
  for_each = var.vpc_id != null ? var.private_subnet_ids : {}

  vpc_id = var.vpc_id

  filter {
    name   = "association.subnet-id"
    values = [each.value]
  }
}

data "aws_route_table" "public" {
  for_each = var.vpc_id != null ? var.public_subnet_ids : {}

  route_table_id = try(data.aws_route_tables.public[each.key].ids[0], data.aws_route_table.existing_main[0].id)

  lifecycle {
    # The jumphost and the public NLB need a public address that routes.
    postcondition {
      condition     = anytrue([for r in self.routes : r.cidr_block == "0.0.0.0/0" && startswith(r.gateway_id == null ? "" : r.gateway_id, "igw-")])
      error_message = "Public subnet ${each.value} needs a 0.0.0.0/0 route to an internet gateway (route table ${self.route_table_id})."
    }
  }
}

data "aws_route_table" "private" {
  for_each = var.vpc_id != null ? var.private_subnet_ids : {}

  route_table_id = try(data.aws_route_tables.private[each.key].ids[0], data.aws_route_table.existing_main[0].id)

  lifecycle {
    # Nodes have no public IP: egress needs a NAT gateway, transit gateway or appliance.
    postcondition {
      condition     = anytrue([for r in self.routes : r.cidr_block == "0.0.0.0/0" && !startswith(r.gateway_id == null ? "" : r.gateway_id, "igw-")])
      error_message = "Private subnet ${each.value} needs a 0.0.0.0/0 route that is not an internet gateway, for example a NAT gateway (route table ${self.route_table_id})."
    }
  }
}

# egress_ips: the NAT gateways the private subnets route through, when any.
data "aws_nat_gateway" "existing" {
  for_each = toset(flatten([
    for k, rt in data.aws_route_table.private : [
      for r in rt.routes : r.nat_gateway_id if r.cidr_block == "0.0.0.0/0" && r.nat_gateway_id != null && r.nat_gateway_id != ""
    ]
  ]))

  id = each.value
}

locals {
  vpc_id             = var.vpc_id != null ? data.aws_vpc.existing[0].id : aws_vpc.this[0].id
  public_subnet_ids  = var.vpc_id != null ? [for z in local.zones : data.aws_subnet.public[z].id] : aws_subnet.public[*].id
  private_subnet_ids = var.vpc_id != null ? [for z in local.zones : data.aws_subnet.private[z].id] : aws_subnet.private[*].id
  existing_vpc_cidr  = var.vpc_id != null ? data.aws_vpc.existing[0].cidr_block : null
  egress_ips         = var.vpc_id != null ? sort([for n in data.aws_nat_gateway.existing : n.public_ip]) : aws_eip.nat[*].public_ip
}
