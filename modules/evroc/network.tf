# One regional VPC spans all zones. Regional: VPC, load balancer, backend pool,
# public IP, security group. Zonal: subnet, disk, VM, placement group, snapshot.
resource "evroc_vpc" "this" {
  name             = "${var.cluster_name}-vpc"
  ipv4_cidr_blocks = [local.vpc_cidr]
  project          = var.project
  region           = var.region
  user_labels      = merge(local.common_labels, { "elemental-role" = "network" })

  # Plan-time input and org-limit checks; every node depends on the VPC.
  lifecycle {
    precondition {
      condition     = local.quota_demand.vcpus <= data.evroc_organization_quota.this.compute_vcpus
      error_message = "vCPU quota: this cluster needs ${local.quota_demand.vcpus} vCPU at its peak (${local.quota_breakdown.vcpus}); the organization limit is ${data.evroc_organization_quota.this.compute_vcpus}. Usage by other workloads is not checked. Use smaller flavors, fewer zones, or ask evroc for a quota increase."
    }
    precondition {
      condition     = local.quota_demand.memory_gb == null || local.quota_memory_gb == null || coalesce(local.quota_demand.memory_gb, 0) <= coalesce(local.quota_memory_gb, 0)
      error_message = "Memory quota: this cluster needs ${coalesce(local.quota_demand.memory_gb, 0)} GB at its peak (${local.quota_breakdown.memory}); the organization limit is ${data.evroc_organization_quota.this.compute_memory}. Usage by other workloads is not checked. Use smaller flavors, fewer zones, or ask evroc for a quota increase."
    }
    precondition {
      condition     = local.quota_demand.public_ips <= data.evroc_organization_quota.this.networking_public_ips
      error_message = "Public IP quota: this cluster needs ${local.quota_demand.public_ips} public IPs (${local.quota_breakdown.public_ips}); the organization limit is ${data.evroc_organization_quota.this.networking_public_ips}. Usage by other workloads is not checked. Set control_plane_public_ip and the pools' public_ip to false, or ask evroc for a quota increase."
    }

    precondition {
      condition     = var.image_id == null
      error_message = "image_id is not supported: evroc snapshots are zonal. Set image_ids, a map of zone to snapshot."
    }

    precondition {
      condition     = length(var.image_ids) == 0 || length(setsubtract(toset(local.zones), keys(var.image_ids))) == 0
      error_message = "image_ids needs an entry for every zone in use (${join(", ", local.zones)}); a node disk can only clone a snapshot of its own zone. Missing: ${join(", ", setsubtract(toset(local.zones), keys(var.image_ids)))}."
    }

    precondition {
      condition     = alltrue([for z in local.zones : contains(["a", "b", "c"], z)])
      error_message = "zones entries must be \"a\", \"b\" or \"c\", the zones of the evroc region."
    }

    precondition {
      condition     = tonumber(split("/", local.vpc_cidr)[1]) >= 16 && tonumber(split("/", local.vpc_cidr)[1]) <= 24
      error_message = "vpc_cidr must be a /16 to /24 block: one subnet per zone is carved out of it with ${local.subnet_newbits} extra prefix bits."
    }

    precondition {
      condition     = local.vpc_mtu >= 1330 && local.vpc_mtu <= 9000
      error_message = "vpc_mtu must be between 1330 and 9000 on evroc; the pod MTU is vpc_mtu - 50 and must stay above 1280."
    }

    precondition {
      condition = alltrue([
        for k, v in var.tags :
        can(regex("^([A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?)$", k))
        && can(regex("^([A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?)?$", v))
      ])
      error_message = "tags become evroc labels: keys and values must start and end with an alphanumeric, contain only [-_.] between, and be at most 63 characters. Keys cannot contain \"/\"."
    }

    precondition {
      condition     = alltrue([for k, v in local.agent_pools : v.kind == "vm"])
      error_message = "worker_pools and gpu_pools kind must be \"vm\"; evroc has no bare-metal nodes."
    }

    precondition {
      condition     = alltrue([for k, v in local.agent_pools : v.placement == null || contains(["spread", "cluster"], coalesce(v.placement, "-"))])
      error_message = "worker_pools and gpu_pools placement must be \"spread\", \"cluster\" or null (no placement group)."
    }

    precondition {
      condition     = alltrue([for k, v in local.agent_pools : can(regex("^[a-z0-9]+[a-z0-9-]*\\.[a-z0-9]+$", v.instance_type))])
      error_message = "worker_pools and gpu_pools instance_type must look like an evroc compute profile name (\"<family>.<size>\", for example \"c1a.m\" or \"gn-l40s.s\")."
    }

    precondition {
      condition     = alltrue([for k, v in local.agent_pools : contains(local.zones, coalesce(v.zone, local.zones[0]))])
      error_message = "Every worker_pools and gpu_pools zone must be one of zones (${join(", ", local.zones)})."
    }

    precondition {
      condition     = alltrue([for k, v in local.agent_pools : contains(local.gpu_zones, coalesce(v.zone, local.zones[0])) if v.role == "gpu"])
      error_message = "evroc admits GPU VMs only in zone(s) ${join(", ", local.gpu_zones)}. Set zone on the gpu_pools entry, or list a GPU zone first in zones (an unpinned pool uses zones[0]). worker_pools may use any zone."
    }
  }
}

# One subnet per zone (zonal), CIDRs from local.subnet_cidrs. Keyed by zone name,
# so removing a zone destroys only its subnet.
resource "evroc_subnet" "this" {
  for_each = toset(local.zones)

  name            = "${var.cluster_name}-subnet-${each.key}"
  vpc_ref         = evroc_vpc.this.fqid
  zone            = each.key
  ipv4_cidr_block = local.subnet_cidrs[each.key]
  project         = var.project
  region          = var.region
  user_labels     = merge(local.common_labels, { "elemental-role" = "network" })
}

# The API VIP, allocated with no dependencies so it is known before the load
# balancer, nodes and image (the image bakes it in; see locals.tf).
resource "evroc_public_ip" "cluster" {
  name    = "${var.cluster_name}-api-vip"
  project = var.project
  region  = var.region

  # role lb: the VIP belongs to the load balancer.
  user_labels = merge(local.common_labels, { "elemental-role" = "lb" })
}

# One "spread" group per zone (placement groups are zonal): keeps control-plane VMs
# on separate hosts. Effective once control_plane_count exceeds the zone count.
resource "evroc_placement_group" "control_plane" {
  for_each = toset(local.zones)

  name     = "${var.cluster_name}-control-plane-pg-${each.key}"
  strategy = "spread"
  zone     = each.key
  project  = var.project
  region   = var.region
  user_labels = merge(local.common_labels, {
    "elemental-role" = "control_plane"
    "elemental-pool" = "cp"
  })
}

# Worker and GPU placement groups per (pool, zone), only for pools that set `placement`. Key
# "<pool>/<zone>" is plan-known.
resource "evroc_placement_group" "agent" {
  for_each = local.agent_placement_groups

  name     = "${var.cluster_name}-${each.value.pool}-pg-${each.value.zone}"
  strategy = each.value.strategy
  zone     = each.value.zone
  project  = var.project
  region   = var.region

  # `pool` on every per-pool object.
  user_labels = merge(local.common_labels, {
    "elemental-role" = each.value.role
    "elemental-pool" = each.value.pool
  })
}
