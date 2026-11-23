# Plan-time checks: a VM size the region or zone does not offer, one the
# subscription is restricted from, or a vCPU quota without headroom fails the
# plan before anything is created. Input checks are preconditions on
# terraform_data.input_checks (network.tf). Capacity can still run out at
# create ("AllocationFailed", "ZonalAllocationFailed"): that cannot be checked.
#
# azurerm has no data source for SKUs or usages, so these are ARM reads through azapi.

locals {
  # Every VM size in use, by what it is for.
  size_inputs = merge(
    local.jumphost_enabled ? { "jumphost" = local.jumphost_type } : {},
    { "control plane" = local.control_plane_type },
    {
      for k, p in local.agent_pools :
      "${p.role == "gpu" ? "GPU" : "worker"} pool \"${k}\"" => p.instance_type
    },
  )

  size_format = "^Standard_[A-Za-z0-9_]+$"

  size_errors = sort([
    for who, s in local.size_inputs : "${who} = \"${s}\" (expected a size name such as Standard_D8s_v5)"
    if !can(regex(local.size_format, s))
  ])

  # Names are interpolated into a JMESPath filter: only the validated ones.
  size_names = sort(distinct([for s in values(local.size_inputs) : s if can(regex(local.size_format, s))]))
}

# One request for the region's VM sizes in use. The filter narrows the list to
# the region; the JMESPath keeps only the sizes this cluster uses (none when the
# size inputs are malformed: the input checks report those).
data "azapi_resource_list" "skus" {
  type      = "Microsoft.Compute/skus@2021-07-01"
  parent_id = "/subscriptions/${var.azure_subscription_id}"

  query_parameters = {
    "$filter" = ["location eq '${local.region}'"]
  }

  response_export_values = {
    sizes = "value[?resourceType=='virtualMachines' && (${length(local.size_names) > 0 ? join(" || ", [for n in local.size_names : "name=='${n}'"]) : "`false`"})].{name: name, family: family, zones: locationInfo[0].zones, restrictions: restrictions, capabilities: capabilities}"
  }
}

locals {
  sku_raw = try(data.azapi_resource_list.skus.output.sizes, [])

  sku_info = {
    for s in local.sku_raw : s.name => {
      family = try(s.family, "")
      vcpus  = try(tonumber({ for c in s.capabilities : c.name => c.value }["vCPUs"]), 0)
      gen2   = contains([for g in split(",", try({ for c in s.capabilities : c.name => c.value }["HyperVGenerations"], "")) : trimspace(g)], "V2")
      # Premium SSD, accelerated networking and the disk controller types come as capability strings.
      premium     = try({ for c in s.capabilities : c.name => c.value }["PremiumIO"], "False") == "True"
      accel       = try({ for c in s.capabilities : c.name => c.value }["AcceleratedNetworkingEnabled"], "False") == "True"
      controllers = [for c in split(",", try({ for c in s.capabilities : c.name => c.value }["DiskControllerTypes"], "SCSI")) : trimspace(c)]

      offered_zones       = try(s.zones, null) == null ? [] : s.zones
      location_restricted = anytrue([for r in s.restrictions : r.type == "Location"])
      restricted_zones    = flatten([for r in s.restrictions : try(r.restrictionInfo.zones, []) if r.type == "Zone"])
    }
  }

  # Zones where the subscription may use the size.
  sku_zones = { for n, s in local.sku_info : n => sort([for z in s.offered_zones : z if !contains(s.restricted_zones, z)]) }

  # Zones in use: var.zones, else the region's logical zones (not the per-size
  # restrictions, which change over time). A region without zones gives [] and
  # nothing is zone-pinned (locals.tf); a size unusable in a zone fails the plan.
  region_zones = sort(try(data.azapi_resource_action.locations.output.zones, []))
  zones        = length(var.zones) > 0 ? var.zones : local.region_zones

  # NVMe-only sizes (the _v6 families) need the NVMe controller; others use SCSI.
  disk_controller = {
    for n, s in local.sku_info : n => (
      !contains(s.controllers, "NVMe") ? "SCSI" :
      !contains(s.controllers, "SCSI") || can(regex("_v6$", n)) ? "NVMe" :
      "SCSI"
    )
  }

  # Where each VM lands. The jumphost is not pinned to a zone.
  placements = concat(
    local.jumphost_enabled ? [{ who = "jumphost", size = local.jumphost_type, zone = null, enabled = true }] : [],
    [for n in local.ignition_nodes : { who = n.who, size = n.instance_type, zone = n.zone, enabled = var.deploy_nodes }],
  )

  placement_errors = sort(distinct(flatten([
    for p in local.placements : (
      !contains(keys(local.sku_info), p.size) ? ["${p.who} = ${p.size} (not offered in ${local.region})"] :
      local.sku_info[p.size].location_restricted ? ["${p.who} = ${p.size} (not available to this subscription in ${local.region}; request access or pick another size)"] :
      !local.sku_info[p.size].gen2 ? ["${p.who} = ${p.size} (no Generation 2 support: the image boots with UEFI)"] :
      local.os_disk_type == "Premium_LRS" && !local.sku_info[p.size].premium ? ["${p.who} = ${p.size} (no Premium SSD support)"] :
      p.zone != null && !contains(local.sku_zones[p.size], p.zone) ? ["${p.who} = ${p.size} (not available in zone ${p.zone}; zones: ${jsonencode(local.sku_zones[p.size])}; set the pool's zone)"] :
      []
    ) if p.enabled
  ])))
}

# The region's logical availability zones: empty for a region without zones.
data "azapi_resource_action" "locations" {
  type        = "Microsoft.Resources/subscriptions@2022-12-01"
  resource_id = "/subscriptions/${var.azure_subscription_id}"
  action      = "locations"
  method      = "GET"

  response_export_values = {
    zones = "value[?name=='${local.region}'].availabilityZoneMappings[].logicalZone"
  }
}

# vCPU quota: per family and regional total, from the subscription's usages.
data "azapi_resource_action" "compute_usages" {
  type        = "Microsoft.Compute/locations@2024-07-01"
  resource_id = "/subscriptions/${var.azure_subscription_id}/providers/Microsoft.Compute/locations/${local.region}"
  action      = "usages"
  method      = "GET"

  response_export_values = {
    usages = "value[].{name: name.value, current: currentValue, limit: limit}"
  }
}

data "azapi_resource_action" "network_usages" {
  type        = "Microsoft.Network/locations@2024-05-01"
  resource_id = "/subscriptions/${var.azure_subscription_id}/providers/Microsoft.Network/locations/${local.region}"
  action      = "usages"
  method      = "GET"

  response_export_values = {
    usages = "value[].{name: name.value, current: currentValue, limit: limit}"
  }
}

# VMs this cluster already runs: the next apply does not add them again.
data "azapi_resource_list" "existing_vms" {
  type      = "Microsoft.Compute/virtualMachines@2024-07-01"
  parent_id = "/subscriptions/${var.azure_subscription_id}"

  response_export_values = {
    vms = "value[?location=='${local.region}' && tags.\"elemental-cluster\"=='${var.cluster_name}'].{size: properties.hardwareProfile.vmSize}"
  }
}

# The cluster's own Standard public IPs and load balancers: already counted in the usages.
data "azapi_resource_list" "existing_public_ips" {
  type      = "Microsoft.Network/publicIPAddresses@2024-05-01"
  parent_id = "/subscriptions/${var.azure_subscription_id}"

  response_export_values = {
    ips = "value[?location=='${local.region}' && sku.name=='Standard' && tags.\"elemental-cluster\"=='${var.cluster_name}'].{name: name}"
  }
}

data "azapi_resource_list" "existing_lbs" {
  type      = "Microsoft.Network/loadBalancers@2024-05-01"
  parent_id = "/subscriptions/${var.azure_subscription_id}"

  response_export_values = {
    lbs = "value[?location=='${local.region}' && sku.name=='Standard' && tags.\"elemental-cluster\"=='${var.cluster_name}'].{name: name}"
  }
}

locals {
  compute_usage = { for u in try(data.azapi_resource_action.compute_usages.output.usages, []) : lower(u.name) => u }
  network_usage = { for u in try(data.azapi_resource_action.network_usages.output.usages, []) : lower(u.name) => u }

  wanted_vcpus = [
    for p in local.placements : {
      family = local.sku_info[p.size].family
      vcpus  = local.sku_info[p.size].vcpus
    } if p.enabled && contains(keys(local.sku_info), p.size)
  ]
  existing_vcpus = [
    for v in try(data.azapi_resource_list.existing_vms.output.vms, []) : {
      family = local.sku_info[v.size].family
      vcpus  = local.sku_info[v.size].vcpus
    } if contains(keys(local.sku_info), v.size)
  ]

  vcpus_needed_by_family = {
    for f in distinct([for w in local.wanted_vcpus : w.family]) : f => (
      sum(concat([0], [for w in local.wanted_vcpus : w.vcpus if w.family == f])) -
      sum(concat([0], [for w in local.existing_vcpus : w.vcpus if w.family == f]))
    )
  }
  vcpus_needed_total = sum(concat([0], [for w in local.wanted_vcpus : w.vcpus])) - sum(concat([0], [for w in local.existing_vcpus : w.vcpus]))

  # Standard public IPs: load balancer, jumphost and, for a created network, the NAT gateway;
  # minus those the cluster already has. The names are those of az network list-usages;
  # a name the region does not list is not checked.
  network_needed = {
    "standardskupublicipaddresses" = 1 + (local.jumphost_enabled ? 1 : 0) + (local.create_network ? 1 : 0) - length(try(data.azapi_resource_list.existing_public_ips.output.ips, []))
    "standardskuloadbalancers"     = 1 - length(try(data.azapi_resource_list.existing_lbs.output.lbs, []))
  }

  quota_short = sort(concat(
    [
      for f, need in local.vcpus_needed_by_family :
      "${f}: needs ${need} more vCPUs, ${local.compute_usage[lower(f)].limit - local.compute_usage[lower(f)].current} left"
      if need > 0 && contains(keys(local.compute_usage), lower(f)) && local.compute_usage[lower(f)].limit - local.compute_usage[lower(f)].current < need
    ],
    [
      for k in ["cores"] :
      "Total Regional vCPUs: needs ${local.vcpus_needed_total} more, ${local.compute_usage[k].limit - local.compute_usage[k].current} left"
      if local.vcpus_needed_total > 0 && contains(keys(local.compute_usage), k) && local.compute_usage[k].limit - local.compute_usage[k].current < local.vcpus_needed_total
    ],
    [
      for k, need in local.network_needed :
      "${k}: needs ${need} more, ${local.network_usage[k].limit - local.network_usage[k].current} left"
      if need > 0 && contains(keys(local.network_usage), k) && local.network_usage[k].limit - local.network_usage[k].current < need
    ],
  ))
}

# Gate for everything that consumes quota.
resource "terraform_data" "limits_check" {
  input = [local.sku_info, local.vcpus_needed_by_family]

  depends_on = [terraform_data.input_checks]

  lifecycle {
    precondition {
      condition     = length(local.placement_errors) == 0
      error_message = "VM sizes not usable: ${join("; ", local.placement_errors)}. GPU sizes need a quota above 0 for their family in the region."
    }

    precondition {
      condition     = length(local.quota_short) == 0
      error_message = "Quota too low in ${local.region}: ${join("; ", local.quota_short)}. Request an increase in the Azure portal (Subscriptions, Usage + quotas)."
    }
  }
}
