# Plan-time input checks. Kept off the VPC, which does not exist with vpc_id.
resource "terraform_data" "input_checks" {
  lifecycle {
    precondition {
      condition     = length(var.zones) <= 1
      error_message = "zones must have at most one entry: this provider has a single location per deployment."
    }

    precondition {
      condition     = var.region != null
      error_message = "region is required on this provider, for example \"ams\"."
    }

    precondition {
      condition     = var.control_plane_disk_size_gb == null && var.jumphost_disk_size_gb == null
      error_message = "control_plane_disk_size_gb and jumphost_disk_size_gb must be null: the plan fixes the disk size."
    }

    precondition {
      condition     = !var.control_plane_public_ip
      error_message = "control_plane_public_ip must be false: control-plane nodes have no public NIC, egress goes through the NAT gateway."
    }

    precondition {
      condition     = length(local.agent_pool_unsupported) == 0
      error_message = "gpu_pools or worker_pools entries ${join(", ", local.agent_pool_unsupported)} set a field this provider does not support: zone, disk_size_gb and placement must be null."
    }

    precondition {
      condition     = length(local.agent_pool_bad_kind) == 0
      error_message = "gpu_pools or worker_pools entries ${join(", ", local.agent_pool_bad_kind)} mix plan family and kind: kind = \"bare_metal\" needs a vbm-* instance_type, kind = \"vm\" a cloud plan."
    }
  }
}

moved {
  from = vultr_vpc.this
  to   = vultr_vpc.this[0]
}

moved {
  from = vultr_nat_gateway.this
  to   = vultr_nat_gateway.this[0]
}

# The original (non-VPC 2.0) VPC, the one wired to vpc_id and vpc_only. The
# subnet is explicit so the range shows in a diff. Not created with var.vpc_id.
resource "vultr_vpc" "this" {
  count = var.vpc_id == null ? 1 : 0

  region         = var.region
  description    = "${var.cluster_name}-vpc"
  v4_subnet      = local.vpc_network
  v4_subnet_mask = local.vpc_prefix
}

# Egress for vpc_only nodes. Also the source address the load balancer sees on
# 9345 joins: apiVIP is the load balancer's public address, so they leave the VPC.
resource "vultr_nat_gateway" "this" {
  count = var.vpc_id == null ? 1 : 0

  vpc_id = vultr_vpc.this[0].id
  label  = "${var.cluster_name}-nat"
  tag    = "elemental-cluster=${var.cluster_name}"
}

# --- Existing VPC (var.vpc_id) ----------------------------------------------
#
# Read only: destroy leaves the VPC and its NAT gateway in place.
data "vultr_vpc" "existing" {
  count = var.vpc_id != null ? 1 : 0

  filter {
    name   = "id"
    values = [var.vpc_id]
  }

  lifecycle {
    postcondition {
      condition     = self.region == var.region
      error_message = "vpc_id ${var.vpc_id} is in region \"${self.region}\", not \"${var.region}\"."
    }

    postcondition {
      condition     = var.vpc_cidr == null || try(cidrhost(var.vpc_cidr, 0) == self.v4_subnet && tonumber(split("/", var.vpc_cidr)[1]) == self.v4_subnet_mask, false)
      error_message = "vpc_cidr (${coalesce(var.vpc_cidr, "null")}) does not match the subnet of vpc_id, ${self.v4_subnet}/${self.v4_subnet_mask}. Leave vpc_cidr null with vpc_id."
    }

    # Same rule as the vpc_cidr validation (variables-common.tf).
    postcondition {
      condition = !anytrue([
        for c in ["10.42.0.0/16", "10.43.0.0/16"] :
        cidrhost(format("%s/%d", self.v4_subnet, min(self.v4_subnet_mask, 16)), 0) == cidrhost(format("%s/%d", cidrhost(c, 0), min(self.v4_subnet_mask, 16)), 0)
      ])
      error_message = "The subnet of vpc_id, ${self.v4_subnet}/${self.v4_subnet_mask}, overlaps the RKE2 default cluster-cidr 10.42.0.0/16 or service-cidr 10.43.0.0/16."
    }
  }
}

# The provider has no NAT gateway data source; read it from the API.
data "http" "nat_gateway" {
  count = var.vpc_id != null ? 1 : 0

  url = "https://api.vultr.com/v2/vpcs/${var.vpc_id}/nat-gateway/${coalesce(var.nat_gateway_id, "-")}"
  request_headers = {
    Accept        = "application/json"
    Authorization = "Bearer ${var.vultr_api_key}"
  }

  retry {
    attempts = 2
  }

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "Vultr returned HTTP ${self.status_code} reading NAT gateway ${var.nat_gateway_id} of VPC ${var.vpc_id}. A 404 means it is not a NAT gateway of that VPC; a 401 means vultr_api_key is missing or invalid."
    }

    postcondition {
      condition     = length(try(jsondecode(self.response_body).nat_gateway.private_ips, [])) > 0 && length(try(jsondecode(self.response_body).nat_gateway.public_ips, [])) > 0
      error_message = "NAT gateway ${var.nat_gateway_id} has no private or public IPv4 yet (status ${try(jsondecode(self.response_body).nat_gateway.status, "unknown")}). Retry once it is active."
    }
  }
}

locals {
  vpc_id            = var.vpc_id != null ? data.vultr_vpc.existing[0].id : vultr_vpc.this[0].id
  existing_vpc_cidr = var.vpc_id != null ? "${data.vultr_vpc.existing[0].v4_subnet}/${data.vultr_vpc.existing[0].v4_subnet_mask}" : null
  vpc_subnet_cidr = (var.vpc_id != null
    ? local.existing_vpc_cidr
    : "${vultr_vpc.this[0].v4_subnet}/${vultr_vpc.this[0].v4_subnet_mask}"
  )

  nat_gateway_public_ips = (var.vpc_id != null
    ? tolist(jsondecode(data.http.nat_gateway[0].response_body).nat_gateway.public_ips)
    : tolist(vultr_nat_gateway.this[0].public_ips)
  )
  nat_gateway_private_ip = (var.vpc_id != null
    ? jsondecode(data.http.nat_gateway[0].response_body).nat_gateway.private_ips[0]
    : vultr_nat_gateway.this[0].private_ips[0]
  )
}
