# Plan-time checks: a bad input or an out-of-stock plan fails before anything
# is created. Stock can still drain between plan and apply. The input checks
# are preconditions on vultr_vpc.this (network.tf).

locals {
  agent_pool_unsupported = sort([
    for k, p in local.agent_pools : k if p.zone != null || p.disk_size_gb != null || p.placement != null
  ])

  agent_pool_bad_kind = sort([
    for k, p in local.agent_pools : k if(p.kind == "bare_metal" ? !startswith(p.instance_type, "vbm-") : startswith(p.instance_type, "vbm-"))
  ])
}

# --- Plan availability -------------------------------------------------------
#
# One untyped query covers every plan family; a missing key yields an empty
# list. See docs/providers/vultr.md#plan-availability.
locals {
  # Pools (GPU or worker) with count = 0 are left out, so a pool can be parked while out
  # of stock.
  agent_pools_active = { for k, p in local.agent_pools : k => p if p.count > 0 }

  # Endpoint behind each active pool's servers.
  agent_existing_endpoints = toset([
    for p in values(local.agent_pools_active) : p.kind == "bare_metal" ? "bare-metals" : "instances"
  ])
}

# Servers that already exist (label, plan, region), so the stock check only
# gates nodes the next apply creates. Read from the API because the nodes
# depend on the check. One page of 500; see docs/providers/vultr.md#plan-availability.
data "http" "agent_existing" {
  for_each = local.agent_existing_endpoints

  url = "https://api.vultr.com/v2/${each.key}?per_page=500"
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
      error_message = "Vultr returned HTTP ${self.status_code} listing ${each.key}. A 401 means vultr_api_key is missing or invalid."
    }
  }
}

locals {
  # "label|plan" of every server in the region. The response's list key is the
  # endpoint name with an underscore (bare-metals -> bare_metals).
  agent_existing = toset(flatten([
    for k, d in data.http.agent_existing : [
      for s in jsondecode(d.response_body)[replace(k, "-", "_")] :
      "${s.label}|${s.plan}" if s.region == var.region
    ]
  ]))

  # Per active pool, the hostnames the next apply would create.
  agent_pool_missing = {
    for k, p in local.agent_pools_active : k => [
      for n in local.agent_nodes : n.hostname
      if n.pool == k && !contains(local.agent_existing, "${n.hostname}|${n.plan}")
    ]
  }

  # Control plane, jumphost and every pool that has something to create.
  requested_plans = merge(
    {
      "control plane" = local.control_plane_plan
      "jumphost"      = local.jumphost_plan
    },
    {
      for k, p in local.agent_pools_active :
      "${p.role == "gpu" ? "GPU" : "worker"} pool \"${k}\" (creates ${join(", ", local.agent_pool_missing[k])})" => p.instance_type
      if length(local.agent_pool_missing[k]) > 0
    },
  )
}

data "http" "plan_availability" {
  url = "https://api.vultr.com/v2/regions/${var.region}/availability"
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
      error_message = "Vultr availability API returned HTTP ${self.status_code} for region \"${var.region}\". A 400 here usually means the region ID is invalid. Response: ${self.response_body}"
    }

    # Reads self, not a local, to avoid a cycle. tolist(): contains() needs a
    # list, jsondecode returns a tuple.
    postcondition {
      condition = alltrue([
        for k, plan in local.requested_plans :
        contains(tolist(try(jsondecode(self.response_body).available_plans, [])), plan)
      ])
      error_message = "Plans not available in region \"${var.region}\": ${join("; ", [for k, plan in local.requested_plans : "${k} = ${plan}" if !contains(tolist(try(jsondecode(self.response_body).available_plans, [])), plan)])}. Bare metal and vcg- plans available there: ${join(", ", coalescelist([for p in tolist(try(jsondecode(self.response_body).available_plans, [])) : p if startswith(p, "vbm-") || startswith(p, "vcg-")], ["<none>"]))}. An empty list can also mean vultr_api_key is missing or invalid; most regions carry little or no GPU stock."
    }
  }
}
