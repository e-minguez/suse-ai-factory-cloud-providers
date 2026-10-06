# Plan-time checks: a bad input, an instance type the organization cannot use
# or a quota without headroom fails before anything is created. The input
# checks are preconditions on exoscale_private_network.this (network.tf).
# Capacity can still run out between plan and apply.

locals {
  agent_pool_unsupported = sort([
    for k, p in local.agent_pools : k if p.zone != null || p.placement != null || p.kind != "vm"
  ])

  # Every node has a public IPv4 (ADR 008): pools must say so explicitly.
  agent_pool_private = sort([for k, p in local.agent_pools : k if !p.public_ip])

  agent_pools_active = { for k, p in local.agent_pools : k => p if p.count > 0 }

  # Instance type per requester, for the availability check and its messages.
  requested_types = merge(
    {
      "control plane" = local.control_plane_type
      "jumphost"      = local.jumphost_type
    },
    {
      for k, p in local.agent_pools_active :
      "${p.role == "gpu" ? "GPU" : "worker"} pool \"${k}\"" => p.instance_type
    },
  )
}

# Signed reads: the instance types the organization may use (the signed list
# omits the others), quotas, and what this cluster already holds, so a re-plan
# only counts what the next apply adds. See docs/providers/exoscale.md#quota-and-availability.
data "external" "api_check" {
  program = ["bash", "${path.module}/scripts/exoscale-api.sh"]

  query = {
    mode       = "check"
    zone       = local.zone
    api_key    = var.exoscale_api_key
    api_secret = var.exoscale_api_secret
    cluster    = var.cluster_name
    types      = join(",", distinct(values(local.requested_types)))
  }
}

locals {
  api_types    = jsondecode(data.external.api_check.result.types)
  api_quotas   = jsondecode(data.external.api_check.result.quotas)
  api_existing = jsondecode(data.external.api_check.result.existing)

  type_unavailable = sort([
    for who, t in local.requested_types : "${who} = ${t}${local.api_types[t].listed ? " (not offered in ${local.zone})" : " (not available to this organization; GPU and large types need activation by Exoscale support)"}"
    if !local.api_types[t].in_zone
  ])

  # GPU pools need a type with GPUs; worker pools one without.
  type_role_mismatch = sort([
    for k, p in local.agent_pools_active : "${k} (${p.instance_type})"
    if local.api_types[p.instance_type].listed && (p.role == "gpu") != (local.api_types[p.instance_type].gpus > 0)
  ])

  # Instances: jumphost, the control plane pool at its target size, agents.
  instances_wanted = 1 + (var.deploy_nodes ? var.control_plane_count + sum(concat([0], [for p in values(local.agent_pools_active) : p.count])) : 0)

  # GPUs per family; Exoscale keeps one quota per GPU family.
  gpus_wanted = var.deploy_nodes ? {
    for f in distinct([for p in values(local.agent_pools_active) : split(".", p.instance_type)[0] if local.api_types[p.instance_type].gpus > 0]) :
    f => sum([for p in values(local.agent_pools_active) : p.count * local.api_types[p.instance_type].gpus if split(".", p.instance_type)[0] == f])
  } : {}

  # A limit of -1 is unlimited; a resource without a quota entry is not checked.
  quota_short = sort(concat(
    [for r, want in merge({ instance = local.instances_wanted, "network-load-balancer" = 1 }, local.gpus_wanted) :
      "${r}: needs ${want - lookup(local.existing_by_quota, r, 0)} more, ${local.api_quotas[r].limit - local.api_quotas[r].usage} left (limit ${local.api_quotas[r].limit})"
      if contains(keys(local.api_quotas), r) && local.api_quotas[r].limit >= 0 &&
    want - lookup(local.existing_by_quota, r, 0) > local.api_quotas[r].limit - local.api_quotas[r].usage],
  ))

  existing_by_quota = merge(
    { instance = local.api_existing.instances, "network-load-balancer" = local.api_existing.nlbs },
    local.api_existing.gpus,
  )
}

# Gate for everything that consumes quota.
resource "terraform_data" "api_check" {
  input = data.external.api_check.id

  lifecycle {
    precondition {
      condition     = length(local.type_unavailable) == 0
      error_message = "Instance types not usable in zone ${local.zone}: ${join("; ", local.type_unavailable)}."
    }

    precondition {
      condition     = length(local.type_role_mismatch) == 0
      error_message = "Pools ${join(", ", local.type_role_mismatch)} use the wrong kind of type: gpu_pools need a GPU type, worker_pools a type without GPUs."
    }

    precondition {
      condition     = length(local.quota_short) == 0
      error_message = "Quota too low in the organization: ${join("; ", local.quota_short)}. GPU quotas are 0 by default; request an increase from Exoscale support."
    }
  }
}
