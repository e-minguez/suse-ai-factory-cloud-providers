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

# DNS support and hostnames stay on for in-VPC name resolution.
resource "aws_vpc" "this" {
  cidr_block           = local.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  # Plan-time input checks; every node depends on the VPC.
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

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-vpc"
    "elemental-role" = "network"
  })
}

# Public subnets: the jumphost and the public NLB. Addresses are assigned
# explicitly, hence map_public_ip_on_launch = false.
resource "aws_subnet" "public" {
  count = local.az_count

  vpc_id                  = aws_vpc.this.id
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
  count = local.az_count

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.private_subnet_cidrs[count.index]
  availability_zone       = local.az_names[count.index]
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-private-${local.az_names[count.index]}"
    "elemental-role" = "network"
  })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-igw"
    "elemental-role" = "network"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-public"
    "elemental-role" = "network"
  })
}

resource "aws_route_table_association" "public" {
  count = local.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One NAT gateway, in the first public subnet, serves every private subnet.
# Losing it interrupts egress only; the API and ingress paths use the NLBs.
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-nat-0"
    "elemental-role" = "network"
  })
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  # The gateway must be created after the internet gateway is attached.
  depends_on = [aws_internet_gateway.this]

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-nat-0"
    "elemental-role" = "network"
  })
}

resource "aws_route_table" "private" {
  count = local.az_count

  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-private-${local.az_names[count.index]}"
    "elemental-role" = "network"
  })
}

resource "aws_route_table_association" "private" {
  count = local.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# Gateway endpoints have no hourly or per-GB charge; S3 traffic skips the NAT gateway.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-s3-endpoint"
    "elemental-role" = "network"
  })
}
