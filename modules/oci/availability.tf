# Plan-time checks: a shape the availability domain does not offer, or a
# service limit without headroom, fails the plan before anything is created.
# Input checks are preconditions on terraform_data.input_checks (network.tf).
# Capacity can still run out at launch ("Out of host capacity"): that cannot be checked.

locals {
  # Where each instance lands: the jumphost in the first zone, nodes as placed in locals.tf.
  placements = concat(
    [{ who = "jumphost", raw = local.jumphost_type, zone = local.zones[0], enabled = local.jumphost_enabled }],
    [for n in local.ignition_nodes : { who = n.who, raw = n.instance_type, zone = n.zone, enabled = var.deploy_nodes }],
  )
}

data "oci_core_shapes" "zone" {
  for_each = local.zone_set

  compartment_id      = var.oci_compartment_ocid
  availability_domain = lookup(local.ad_names, each.key, null)
}

locals {
  offered_shapes = { for z in local.zone_set : z => [for s in data.oci_core_shapes.zone[z].shapes : s.name] }

  shape_unavailable = sort(distinct([
    for p in local.placements : "${p.who} = ${local.shapes[p.raw].name} (not offered in ${p.zone})"
    if p.enabled && !contains(try(local.offered_shapes[p.zone], []), local.shapes[p.raw].name)
  ]))
}

# Service limits. Compute limit names per shape family: flex shapes
# VM.Standard.<E|A><n>.Flex use standard-<e|a><n>-core-count and -memory-count,
# VM.Standard3.Flex uses standard3-*, VM.GPU.A10.<n> uses gpu-a10-count and
# VM.GPU3.<n> gpu3-count. Names for the E5 and A10 families were read from a
# tenancy; the others follow the same pattern. Other families are not checked.
locals {
  existing_usage_instances = [
    for i in data.oci_core_instances.existing.instances : {
      name   = i.shape
      zone   = lower(regex("AD-[0-9]+$", upper(i.availability_domain)))
      ocpus  = try(i.shape_config[0].ocpus, 0)
      memory = try(i.shape_config[0].memory_in_gbs, 0)
    } if try(i.freeform_tags["elemental-cluster"], "") == var.cluster_name
  ]

  limit_family = {
    for n in distinct(concat([for s in values(local.shapes) : s.name], [for i in local.existing_usage_instances : i.name])) : n => (
      can(regex("^VM\\.Standard\\.[EA][0-9]+\\.Flex$", n)) ? "standard-${lower(regex("^VM\\.Standard\\.([EA][0-9]+)\\.Flex$", n)[0])}" :
      n == "VM.Standard3.Flex" ? "standard3" :
      null
    )
  }

  # GPU limit per shape: VM.GPU.A10.<n> -> gpu-a10-count (verified); VM.GPU<g>.<n> -> gpu<g>-count (pattern).
  gpu_limit = {
    for n in keys(local.limit_family) : n => (
      can(regex("^VM\\.GPU\\.[A-Z0-9]+\\.[0-9]+$", n)) ? { name = "gpu-${lower(regex("^VM\\.GPU\\.([A-Z0-9]+)\\.[0-9]+$", n)[0])}-count", amount = tonumber(regex("[0-9]+$", n)) } :
      can(regex("^VM\\.GPU[0-9]+\\.[0-9]+$", n)) ? { name = "gpu${regex("^VM\\.GPU([0-9]+)\\.[0-9]+$", n)[0]}-count", amount = tonumber(regex("[0-9]+$", n)) } :
      null
    )
  }

  instance_demand = concat(
    # Wanted instances.
    [for p in local.placements : {
      zone = p.zone, name = local.shapes[p.raw].name, ocpus = local.shapes[p.raw].ocpus, memory = local.shapes[p.raw].memory, sign = 1
    } if p.enabled],
    # Already created by this cluster: the next apply does not add them again.
    [for i in local.existing_usage_instances : merge(i, { sign = -1 })],
  )

  limit_entries = flatten([
    for d in local.instance_demand : concat(
      local.limit_family[d.name] == null ? [] : [
        { key = "compute|${local.limit_family[d.name]}-core-count|${d.zone}", amount = d.sign * coalesce(d.ocpus, 0) },
        { key = "compute|${local.limit_family[d.name]}-memory-count|${d.zone}", amount = d.sign * coalesce(d.memory, 0) },
      ],
      local.gpu_limit[d.name] == null ? [] : [{ key = "compute|${local.gpu_limit[d.name].name}|${d.zone}", amount = d.sign * local.gpu_limit[d.name].amount }],
    )
  ])

  # Regional limits: this module adds one NLB and one reserved public IP.
  regional_entries = [
    { key = "network-load-balancer-api|max-nlb-flexible-count|", amount = 1 - length(local.existing_nlbs) },
    { key = "vcn|reserved-public-ip-count|", amount = 1 - length(local.existing_reserved_ips) },
  ]

  limit_demand = {
    for key in distinct([for e in concat(local.limit_entries, local.regional_entries) : e.key]) :
    key => sum([for e in concat(local.limit_entries, local.regional_entries) : e.amount if e.key == key])
  }

  limit_query = {
    for key, want in local.limit_demand : key => {
      service = split("|", key)[0]
      name    = split("|", key)[1]
      zone    = split("|", key)[2]
    } if want > 0
  }
}

# The name filter narrows the list; the cluster tag decides (other clusters can share the prefix).
data "oci_core_instances" "existing" {
  compartment_id = var.oci_compartment_ocid

  filter {
    name   = "display_name"
    values = ["^${var.cluster_name}-"]
    regex  = true
  }

  filter {
    name   = "state"
    values = ["PROVISIONING", "RUNNING", "STARTING", "STOPPING", "STOPPED", "MOVING", "CREATING_IMAGE"]
  }
}

data "oci_network_load_balancer_network_load_balancers" "existing" {
  compartment_id = var.oci_compartment_ocid
  display_name   = "${var.cluster_name}-lb"
}

data "oci_core_public_ips" "existing" {
  compartment_id = var.oci_compartment_ocid
  scope          = "REGION"
  lifetime       = "RESERVED"

  filter {
    name   = "display_name"
    values = ["${var.cluster_name}-lb"]
  }
}

locals {
  existing_nlbs         = flatten(data.oci_network_load_balancer_network_load_balancers.existing.network_load_balancer_collection[*].items)
  existing_reserved_ips = data.oci_core_public_ips.existing.public_ips
}

data "oci_limits_resource_availability" "this" {
  for_each = local.limit_query

  compartment_id      = var.oci_tenancy_ocid
  service_name        = each.value.service
  limit_name          = each.value.name
  availability_domain = each.value.zone == "" ? null : lookup(local.ad_names, each.value.zone, null)
}

locals {
  limit_short = sort([
    for key, q in local.limit_query :
    "${q.name}${q.zone == "" ? "" : " in ${q.zone}"}: needs ${local.limit_demand[key]} more, ${data.oci_limits_resource_availability.this[key].available} left"
    if try(tonumber(data.oci_limits_resource_availability.this[key].available) < local.limit_demand[key], false)
  ])
}

# Gate for everything that consumes quota.
resource "terraform_data" "limits_check" {
  input = [local.offered_shapes, local.limit_demand]

  depends_on = [terraform_data.input_checks]

  lifecycle {
    precondition {
      condition     = length(local.shape_unavailable) == 0
      error_message = "Shapes not offered in the availability domain: ${join("; ", local.shape_unavailable)}. GPU shapes need a service limit above 0 in that domain."
    }

    precondition {
      condition     = length(local.limit_short) == 0
      error_message = "Service limits too low in the tenancy: ${join("; ", local.limit_short)}. Request an increase in the OCI console (Governance, Limits)."
    }
  }
}
