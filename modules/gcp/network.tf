# Custom-mode VPC with one regional subnet for every node and the jumphost, and
# a Cloud NAT on a reserved address for node egress. VPCs, subnets, routers and
# NATs carry no labels: their names start with the cluster name. With vpc_id the
# module creates none of this and reads the existing VPC and subnet instead.

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

    # Existing network (vpc_id): every check passes trivially when the module creates it.
    precondition {
      condition     = local.create_network || (local.network_ref != null && local.subnet_ref != null)
      error_message = "vpc_id must be a VPC network name or self link and subnet_id a subnet name or self link (projects/<project>/regions/<region>/subnetworks/<name>)."
    }

    precondition {
      condition     = local.create_network || (local.network_ref != null && local.subnet_ref != null && local.network_ref.project == var.gcp_project && local.subnet_ref.project == var.gcp_project && (local.subnet_ref.region == null || local.subnet_ref.region == local.region))
      error_message = "vpc_id and subnet_id must be in project ${var.gcp_project}, and subnet_id in region ${local.region}: Shared VPC networks of another project are not supported."
    }

    precondition {
      condition     = local.create_network || endswith(try(data.google_compute_subnetwork.existing[0].network, ""), "/projects/${var.gcp_project}/global/networks/${try(local.network_ref.name, "-")}")
      error_message = "subnet_id ${coalesce(var.subnet_id, "-")} does not belong to the VPC network ${coalesce(var.vpc_id, "-")}."
    }

    precondition {
      condition     = local.create_network || var.vpc_cidr == null || var.vpc_cidr == try(data.google_compute_subnetwork.existing[0].ip_cidr_range, "")
      error_message = "vpc_cidr ${coalesce(var.vpc_cidr, "-")} is not the primary range of subnet ${coalesce(var.subnet_id, "-")} (${try(data.google_compute_subnetwork.existing[0].ip_cidr_range, "-")}): leave vpc_cidr null."
    }

    precondition {
      condition     = pow(2, 32 - local.vpc_prefix) - 4 >= local.addresses_needed
      error_message = "The subnet ${local.vpc_cidr} has ${pow(2, 32 - local.vpc_prefix) - 4} usable addresses, the cluster needs ${local.addresses_needed} (nodes, jumphost and the internal load balancer address)."
    }

    precondition {
      condition     = var.image_id == null || length(trimspace(var.image_id)) > 0
      error_message = "image_id must be an image name, self link or family path, or null."
    }
  }
}

resource "google_compute_network" "this" {
  count = local.create_network ? 1 : 0

  depends_on = [terraform_data.input_checks]

  name                    = var.cluster_name
  description             = "SUSE AI Factory cluster ${var.cluster_name}"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
  mtu                     = local.vpc_mtu
}

resource "google_compute_subnetwork" "this" {
  count = local.create_network ? 1 : 0

  name          = var.cluster_name
  description   = "Nodes and jumphost of ${var.cluster_name}"
  network       = google_compute_network.this[0].id
  region        = local.region
  ip_cidr_range = local.vpc_cidr
}

# Reserved, so the egress address survives a replaced NAT and can go on allow-lists.
resource "google_compute_address" "nat" {
  count = local.create_network ? 1 : 0

  depends_on = [terraform_data.limits_check]

  name         = "${var.cluster_name}-nat"
  description  = "Cloud NAT egress address of ${var.cluster_name}"
  region       = local.region
  address_type = "EXTERNAL"
  labels       = merge(local.labels, { "elemental-role" = "network" })
}

resource "google_compute_router" "this" {
  count = local.create_network ? 1 : 0

  name    = var.cluster_name
  network = google_compute_network.this[0].id
  region  = local.region
}

resource "google_compute_router_nat" "this" {
  count = local.create_network ? 1 : 0

  name                               = var.cluster_name
  router                             = google_compute_router.this[0].name
  region                             = local.region
  nat_ip_allocate_option             = "MANUAL_ONLY"
  nat_ips                            = [google_compute_address.nat[0].self_link]
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# Existing network (vpc_id, subnet_id). Cloud NAT cannot be read back, so its
# addresses come from nat_ips.
data "google_compute_network" "existing" {
  count = local.create_network ? 0 : 1

  name    = try(local.network_ref.name, "invalid")
  project = var.gcp_project
}

data "google_compute_subnetwork" "existing" {
  count = local.create_network ? 0 : 1

  name    = try(local.subnet_ref.name, "invalid")
  region  = local.region
  project = var.gcp_project
}

locals {
  create_network = var.vpc_id == null

  # Name, project and (subnets) region from a name, a path or a self link; null when malformed.
  ref_prefix  = "(?:(?:https://www\\.googleapis\\.com/compute/v1/)?projects/(?P<project>[a-z][a-z0-9-]*[a-z0-9])/%s/)?(?P<name>[a-z](?:[-a-z0-9]*[a-z0-9])?)$"
  network_ref = var.vpc_id == null ? null : try({ for k, v in merge({ project = null, name = null }, regex(format("^${local.ref_prefix}", "global/networks"), var.vpc_id)) : k => v == null && k == "project" ? var.gcp_project : v }, null)
  subnet_re   = format("^${local.ref_prefix}", "regions/(?P<region>[a-z0-9-]+)/subnetworks")
  subnet_ref  = var.subnet_id == null ? null : try({ for k, v in merge({ project = null, name = null, region = null }, regex(local.subnet_re, var.subnet_id)) : k => v == null && k == "project" ? var.gcp_project : v }, null)

  network_self_link    = local.create_network ? google_compute_network.this[0].self_link : data.google_compute_network.existing[0].self_link
  subnetwork_self_link = local.create_network ? google_compute_subnetwork.this[0].self_link : data.google_compute_subnetwork.existing[0].self_link
  network_id           = local.create_network ? google_compute_network.this[0].id : data.google_compute_network.existing[0].self_link
  subnetwork_id        = local.create_network ? google_compute_subnetwork.this[0].id : data.google_compute_subnetwork.existing[0].self_link

  # Addresses of the Cloud NAT: reserved here, or listed by the user for an existing network.
  egress_ips = local.create_network ? tolist([google_compute_address.nat[0].address]) : var.nat_ips

  # Nodes, jumphost and the internal load balancer address; the build host is the jumphost.
  addresses_needed = length(local.ignition_nodes) + 2
}
