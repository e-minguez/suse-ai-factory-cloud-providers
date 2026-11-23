# Custom-mode VPC with one regional subnet for every node and the jumphost, and
# a Cloud NAT on a reserved address for node egress. VPCs, subnets, routers and
# NATs carry no labels: their names start with the cluster name.

locals {
  # Names derive from the cluster name; GCP resources are limited to 63 characters.
  name_prefix_max = 30

  cidr_overlaps = { for c in ["10.42.0.0/16", "10.43.0.0/16"] : c => (
    cidrhost(format("%s/%d", cidrhost(local.vpc_cidr, 0), min(local.vpc_prefix, 16)), 0) == cidrhost(format("%s/%d", cidrhost(c, 0), min(local.vpc_prefix, 16)), 0)
  ) }

  label_key_format   = "^[a-z][a-z0-9_-]{0,62}$"
  label_value_format = "^[a-z0-9_-]{0,63}$"
}

# Plan-time input checks; everything else is gated on the limits check (availability.tf).
resource "terraform_data" "input_checks" {
  lifecycle {
    precondition {
      condition     = length(var.cluster_name) <= local.name_prefix_max
      error_message = "cluster_name must be at most ${local.name_prefix_max} characters: GCP resource names (firewall rules, backend services, instance groups) are limited to 63 and carry a suffix."
    }

    precondition {
      condition     = can(regex("^[a-z]", var.cluster_name))
      error_message = "cluster_name must start with a lowercase letter: GCP resource names (VPC, instances, disks, images) must."
    }

    precondition {
      condition     = alltrue([for k, v in var.tags : can(regex(local.label_key_format, k)) && can(regex(local.label_value_format, v))])
      error_message = "tags must follow GCP label rules: keys 1-63 characters starting with a lowercase letter, keys and values only lowercase letters, digits, \"_\" and \"-\", values up to 63 characters."
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
      condition     = length(local.machine_type_errors) == 0
      error_message = "Invalid instance types: ${join("; ", local.machine_type_errors)}."
    }

    precondition {
      condition     = alltrue([for z in local.zones : startswith(z, "${local.region}-")])
      error_message = "zones must be full zone names inside ${local.region}, for example \"${local.region}-a\"; got ${jsonencode(local.zones)}."
    }

    precondition {
      condition     = length(setsubtract(local.zone_set, data.google_compute_zones.region.names)) == 0
      error_message = "zones ${jsonencode(sort(setsubtract(local.zone_set, data.google_compute_zones.region.names)))} are not available in ${local.region}: the zones that are up are ${jsonencode(sort(data.google_compute_zones.region.names))}."
    }

    precondition {
      condition     = alltrue([for k, p in local.agent_pools : p.zone == null || contains(local.zone_set, p.zone)])
      error_message = "A pool zone must be one of the cluster zones: ${jsonencode(local.zones)}."
    }

    precondition {
      condition     = local.vpc_prefix >= 16 && local.vpc_prefix <= 28
      error_message = "vpc_cidr must be a /16 to /28: it is the one regional subnet."
    }

    precondition {
      condition     = local.vpc_mtu >= 1300 && local.vpc_mtu <= 8896
      error_message = "vpc_mtu must be between 1300 and 8896: the range Google Cloud accepts for a VPC."
    }

    precondition {
      condition     = !anytrue([for c in ["10.42.0.0/16", "10.43.0.0/16"] : local.cidr_overlaps[c]])
      error_message = "vpc_cidr ${local.vpc_cidr} overlaps the RKE2 default cluster-cidr 10.42.0.0/16 or service-cidr 10.43.0.0/16."
    }

    precondition {
      condition     = var.image_id == null || length(trimspace(var.image_id)) > 0
      error_message = "image_id must be an image name, self link or family path, or null."
    }
  }
}

resource "google_compute_network" "this" {
  depends_on = [terraform_data.input_checks]

  name                    = var.cluster_name
  description             = "SUSE AI Factory cluster ${var.cluster_name}"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
  mtu                     = local.vpc_mtu
}

resource "google_compute_subnetwork" "this" {
  name          = var.cluster_name
  description   = "Nodes and jumphost of ${var.cluster_name}"
  network       = google_compute_network.this.id
  region        = local.region
  ip_cidr_range = local.vpc_cidr
}

# Reserved, so the egress address survives a replaced NAT and can go on allow-lists.
resource "google_compute_address" "nat" {
  depends_on = [terraform_data.limits_check]

  name         = "${var.cluster_name}-nat"
  description  = "Cloud NAT egress address of ${var.cluster_name}"
  region       = local.region
  address_type = "EXTERNAL"
  labels       = merge(local.labels, { "elemental-role" = "network" })
}

resource "google_compute_router" "this" {
  name    = var.cluster_name
  network = google_compute_network.this.id
  region  = local.region
}

resource "google_compute_router_nat" "this" {
  name                               = var.cluster_name
  router                             = google_compute_router.this.name
  region                             = local.region
  nat_ip_allocate_option             = "MANUAL_ONLY"
  nat_ips                            = [google_compute_address.nat.self_link]
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}
