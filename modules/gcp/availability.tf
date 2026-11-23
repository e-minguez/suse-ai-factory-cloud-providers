# Plan-time checks: a machine type the zone does not offer, or a quota without
# headroom, fails the plan before anything is created. Input checks are
# preconditions on terraform_data.input_checks (network.tf). Capacity can still
# run out at launch (ZONE_RESOURCE_POOL_EXHAUSTED): that cannot be checked.

locals {
  # Where each instance lands: the jumphost in the first zone, nodes as placed in locals.tf.
  placements = concat(
    [{
      who           = "jumphost", name = "${var.cluster_name}-jumphost", type = local.jumphost_type, zone = local.zones[0],
      enabled       = local.jumphost_enabled, public = true, disk_gb = local.jumphost_disk_gb, disk_type = local.boot_disk_type[local.jumphost_type],
      extra_disk_gb = local.build_image ? local.image_target_gb : 0
    }],
    [for n in local.ignition_nodes : {
      who       = n.who, name = n.hostname, type = n.instance_type, zone = n.zone,
      enabled   = var.deploy_nodes, public = n.public_ip, disk_gb = n.disk_size_gb, extra_disk_gb = 0,
      disk_type = local.node_boot_disk_type[n.instance_type]
    }],
  )

  # Custom machine types (<family>-custom-<vcpus>-<memory_mb>) are not in the list API.
  custom_type_format = "^[a-z0-9]+-custom-[0-9]+-[0-9]+$"
  listed_pairs = toset([
    for p in local.placements : "${p.zone}|${p.type}"
    if p.enabled && can(regex(local.machine_type_format, p.type)) && !can(regex(local.custom_type_format, p.type)) && contains(data.google_compute_zones.region.names, p.zone)
  ])
}

# One list call per zone and type: an empty result means the zone does not offer it.
data "google_compute_machine_types" "this" {
  for_each = local.listed_pairs

  project = var.gcp_project
  zone    = split("|", each.key)[0]
  filter  = "name = \"${split("|", each.key)[1]}\""
}

locals {
  offered = { for k, d in data.google_compute_machine_types.this : k => length(d.machine_types) > 0 }

  type_unavailable = sort(distinct([
    for p in local.placements : "${p.who} = ${p.type} (not offered in ${p.zone})"
    if p.enabled && !lookup(local.offered, "${p.zone}|${p.type}", true)
  ]))

  # vCPUs and accelerators per machine type, from any zone that lists it.
  type_info = {
    for t in local.machine_type_names : t => (
      can(regex(local.custom_type_format, t)) ? { cpus = try(tonumber(split("-", t)[2]), 0), gpu_type = null, gpus = 0 } : try(
        {
          cpus     = [for k, d in data.google_compute_machine_types.this : d.machine_types[0] if endswith(k, "|${t}") && length(d.machine_types) > 0][0].guest_cpus
          gpu_type = try([for k, d in data.google_compute_machine_types.this : d.machine_types[0] if endswith(k, "|${t}") && length(d.machine_types) > 0][0].accelerators[0].guest_accelerator_type, null)
          gpus     = try([for k, d in data.google_compute_machine_types.this : d.machine_types[0] if endswith(k, "|${t}") && length(d.machine_types) > 0][0].accelerators[0].guest_accelerator_count, 0)
        },
        { cpus = 0, gpu_type = null, gpus = 0 }
      )
    )
  }
}

# Quotas come from the Compute API (limit and usage per metric). The region and
# project reads, the cluster's existing instances and its existing reserved
# addresses are plain GETs with the provider's access token.
locals {
  compute_api    = "https://compute.googleapis.com/compute/v1/projects/${var.gcp_project}"
  api_headers    = { Authorization = "Bearer ${data.google_client_config.this.access_token}", Accept = "application/json" }
  cluster_filter = urlencode("labels.elemental-cluster=${var.cluster_name}")
}

data "http" "region" {
  url             = "${local.compute_api}/regions/${local.region}"
  request_headers = local.api_headers
}

data "http" "project" {
  url             = local.compute_api
  request_headers = local.api_headers
}

data "http" "existing_instances" {
  url             = "${local.compute_api}/aggregated/instances?maxResults=500&fields=items/*/instances/name&filter=${local.cluster_filter}"
  request_headers = local.api_headers
}

data "http" "existing_addresses" {
  url             = "${local.compute_api}/regions/${local.region}/addresses?maxResults=500&fields=items/name&filter=${local.cluster_filter}"
  request_headers = local.api_headers
}

locals {
  region_quotas = {
    for q in try(jsondecode(data.http.region.response_body).quotas, []) : q.metric => { limit = q.limit, usage = q.usage }
  }
  project_quotas = {
    for q in try(jsondecode(data.http.project.response_body).quotas, []) : q.metric => { limit = q.limit, usage = q.usage }
  }

  existing_instances = toset(flatten([
    for z, v in try(jsondecode(data.http.existing_instances.response_body).items, {}) : [for i in try(v.instances, []) : i.name]
  ]))
  existing_addresses = toset([for a in try(jsondecode(data.http.existing_addresses.response_body).items, []) : a.name])

  # Instances this apply adds; ones that exist already are in the usage figures.
  new_placements = [for p in local.placements : p if p.enabled && !contains(local.existing_instances, p.name)]

  # Per machine family quota (N2_CPUS, C3_CPUS, G2_CPUS...) when the region has one; E2 and N1 use CPUS.
  cpu_metric = {
    for t in local.machine_type_names : t => (
      contains(keys(local.region_quotas), "${upper(local.machine_family[t])}_CPUS") ? "${upper(local.machine_family[t])}_CPUS" :
      contains(["e2", "n1"], local.machine_family[t]) ? "CPUS" : null
    )
  }
  # nvidia-l4 -> NVIDIA_L4_GPUS; nvidia-tesla-a100 -> NVIDIA_A100_GPUS. Types without a match are not checked.
  gpu_metric = {
    for t in local.machine_type_names : t => (
      local.type_info[t].gpu_type == null ? null :
      "${upper(replace(replace(local.type_info[t].gpu_type, "nvidia-tesla-", "nvidia-"), "-", "_"))}_GPUS"
    )
  }

  new_static_addresses = length([for a in ["${var.cluster_name}-nat", "${var.cluster_name}-lb-external"] : a if !contains(local.existing_addresses, a)])

  region_entries = concat(
    flatten([for p in local.new_placements : concat(
      local.cpu_metric[p.type] == null ? [] : [{ metric = local.cpu_metric[p.type], amount = local.type_info[p.type].cpus }],
      local.gpu_metric[p.type] == null ? [] : [{ metric = local.gpu_metric[p.type], amount = local.type_info[p.type].gpus }],
      contains(["pd-balanced", "pd-ssd"], p.disk_type) ? [{ metric = "SSD_TOTAL_GB", amount = p.disk_gb + p.extra_disk_gb }] : [],
      p.disk_type == "pd-standard" ? [{ metric = "DISKS_TOTAL_GB", amount = p.disk_gb + p.extra_disk_gb }] : [],
      p.public ? [{ metric = "IN_USE_ADDRESSES", amount = 1 }] : [],
    )]),
    [
      { metric = "STATIC_ADDRESSES", amount = local.new_static_addresses },
      { metric = "IN_USE_ADDRESSES", amount = local.new_static_addresses },
    ],
  )
  project_entries = concat(
    [for p in local.new_placements : { metric = "GPUS_ALL_REGIONS", amount = local.type_info[p.type].gpus }],
    [for p in local.new_placements : { metric = "CPUS_ALL_REGIONS", amount = local.type_info[p.type].cpus }],
  )

  region_demand  = { for m in distinct([for e in local.region_entries : e.metric]) : m => sum([for e in local.region_entries : e.amount if e.metric == m]) }
  project_demand = { for m in distinct([for e in local.project_entries : e.metric]) : m => sum([for e in local.project_entries : e.amount if e.metric == m]) }

  quota_short = sort(concat(
    [
      for m, want in local.region_demand :
      "${m} in ${local.region}: needs ${want} more, ${floor(local.region_quotas[m].limit - local.region_quotas[m].usage)} left"
      if want > 0 && contains(keys(local.region_quotas), m) && local.region_quotas[m].limit - local.region_quotas[m].usage < want
    ],
    [
      for m, want in local.project_demand :
      "${m} (project): needs ${want} more, ${floor(local.project_quotas[m].limit - local.project_quotas[m].usage)} left"
      if want > 0 && contains(keys(local.project_quotas), m) && local.project_quotas[m].limit - local.project_quotas[m].usage < want
    ],
  ))
}

# Gate for everything that consumes quota.
resource "terraform_data" "limits_check" {
  input = [local.offered, local.region_demand, local.project_demand]

  depends_on = [terraform_data.input_checks]

  lifecycle {
    precondition {
      condition     = data.http.region.status_code == 200 && data.http.project.status_code == 200
      error_message = "Reading quotas of project ${var.gcp_project} failed (HTTP ${data.http.region.status_code} for region ${local.region}, ${data.http.project.status_code} for the project). Check that compute.googleapis.com is enabled, the credentials may read the project (compute.regions.get, compute.projects.get) and gcp_project is the project ID."
    }

    precondition {
      condition     = length(local.type_unavailable) == 0
      error_message = "Machine types not offered in the zone: ${join("; ", local.type_unavailable)}. GPU machine types are offered in a few zones only."
    }

    precondition {
      condition     = length(local.quota_short) == 0
      error_message = "Quota too low in project ${var.gcp_project}: ${join("; ", local.quota_short)}. Request an increase in the Google Cloud console (IAM and admin, Quotas and system limits)."
    }
  }
}
