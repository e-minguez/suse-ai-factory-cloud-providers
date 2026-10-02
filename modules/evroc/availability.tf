# Queried live from the platform API: what evroc offers now in this project and
# region. A requested flavor that is not offered fails the plan.
data "evroc_compute_profiles" "this" {
  lifecycle {
    postcondition {
      condition     = alltrue([for k, f in local.requested_flavors : contains(self.profiles, f)])
      error_message = "Requested flavors not offered by evroc: ${join(", ", [for k, f in local.requested_flavors : "${k} = \"${f}\"" if !contains(self.profiles, f)])}. Available profiles: ${join(", ", self.profiles)}"
    }

    postcondition {
      condition     = alltrue([for k, v in var.worker_pools : coalesce(try([for d in self.details : d.gpu_quantity if d.name == v.instance_type][0], 0), 0) == 0])
      error_message = "worker_pools flavors must not be GPU flavors: ${join(", ", [for k, v in var.worker_pools : "${k} = \"${v.instance_type}\"" if coalesce(try([for d in self.details : d.gpu_quantity if d.name == v.instance_type][0], 0), 0) > 0])}. Use gpu_pools for GPU flavors."
    }
  }
}

locals {
  # Flavors about to be requested, keyed by consumer so errors name it.
  requested_flavors = merge(
    {
      "control-plane" = local.control_plane_instance_type
      "jumphost"      = local.jumphost_instance_type
    },
    {
      for k, v in var.worker_pools :
      "worker pool \"${k}\"" => v.instance_type
    },
    {
      for k, v in var.gpu_pools :
      "gpu pool \"${k}\"" => v.instance_type
    },
  )

  # Per-profile vcpus, memory and GPU details, keyed by profile name.
  compute_profile_details = {
    for d in data.evroc_compute_profiles.this.details : d.name => d
  }

  # GPU quota is counted in GPUs, not VMs (gn-l40s.s = 1, .m = 2, .l = 4), and the
  # provider has no GPU quota data source, so count * gpu_quantity is exposed via
  # gpu_quota_request.
  gpu_pool_demand = {
    for k, v in var.gpu_pools : k => {
      instance_type = v.instance_type
      model         = try(local.compute_profile_details[v.instance_type].gpu_model, "unknown")
      gpus          = v.count * coalesce(try(local.compute_profile_details[v.instance_type].gpu_quantity, 0), 0)
      vcpus         = v.count * try(local.compute_profile_details[v.instance_type].vcpus, 0)
    }
  }

  # Summed per GPU model, the granularity of the quota.
  gpu_demand_by_model = {
    for model in distinct([for d in local.gpu_pool_demand : d.model]) :
    model => sum([for d in local.gpu_pool_demand : d.gpus if d.model == model])
  }
}

# Org-wide compute and networking quota (evroc_project_quota covers object
# storage only): the vCPU, memory and public IP limits enforced at create time.
# Only the limits are used; other workloads' usage is not checked.
data "evroc_organization_quota" "this" {}

locals {
  quota_flavors = distinct(concat(
    [local.jumphost_instance_type, local.control_plane_instance_type],
    [for k, v in var.worker_pools : v.instance_type],
  ))

  # Worker nodes (non-GPU flavors) draw from the compute quota once nodes deploy.
  worker_vcpus = sum(concat([0], [for k, v in var.worker_pools : v.count * local.flavor_vcpus[v.instance_type]]))
  worker_memory_gb = try(
    sum(concat([0], [for k, v in var.worker_pools : v.count * local.flavor_memory_gb[v.instance_type]])),
    null
  )

  flavor_vcpus = {
    for f in local.quota_flavors :
    f => try(local.compute_profile_details[f].vcpus, 0)
  }

  # Memory in GB. The quota is a string ("160GB"), the profiles a number plus a
  # unit; an unknown unit yields null and skips the memory comparison.
  memory_unit_gb = { MB = 0.001, GB = 1, TB = 1000 }
  flavor_memory_gb = {
    for f in local.quota_flavors :
    f => try(local.compute_profile_details[f].memory_amount * local.memory_unit_gb[upper(local.compute_profile_details[f].memory_unit)], null)
  }
  quota_memory_gb = try(
    tonumber(regex("^([0-9.]+)", replace(data.evroc_organization_quota.this.compute_memory, " ", ""))[0])
    * local.memory_unit_gb[upper(regex("[A-Za-z]+$", data.evroc_organization_quota.this.compute_memory))],
    null
  )

  # Peak over the passes. Pass 1: jumphost + one builder per other zone. Pass 2:
  # builders are gone (image.tf); jumphost + control planes + worker_pools
  # nodes (GPU nodes draw no vCPU or memory here). Public IPs: API VIP +
  # jumphost + optional per-node IPs.
  quota_demand = {
    vcpus = max(
      length(local.zones) * local.flavor_vcpus[local.jumphost_instance_type],
      local.flavor_vcpus[local.jumphost_instance_type] + var.control_plane_count * local.flavor_vcpus[local.control_plane_instance_type] + local.worker_vcpus,
    )
    memory_gb = try(max(
      length(local.zones) * local.flavor_memory_gb[local.jumphost_instance_type],
      local.flavor_memory_gb[local.jumphost_instance_type] + var.control_plane_count * local.flavor_memory_gb[local.control_plane_instance_type] + local.worker_memory_gb,
    ), null)
    public_ips = (
      2
      + (var.control_plane_public_ip ? var.control_plane_count : 0)
      + length([for n in local.agent_nodes : n if n.public_ip])
    )
  }
}

locals {
  # Per-resource breakdown for the error messages of the checks on
  # evroc_vpc.this (network.tf).
  worker_breakdown = join("", [for k in sort(keys(var.worker_pools)) : " + ${var.worker_pools[k].count} x ${var.worker_pools[k].instance_type} (worker pool ${k})"])

  quota_breakdown = {
    vcpus      = "pass 1: ${length(local.zones)} x ${local.jumphost_instance_type} (jumphost + builders) = ${length(local.zones) * local.flavor_vcpus[local.jumphost_instance_type]}; pass 2: 1 x ${local.jumphost_instance_type} + ${var.control_plane_count} x ${local.control_plane_instance_type}${local.worker_breakdown} = ${local.flavor_vcpus[local.jumphost_instance_type] + var.control_plane_count * local.flavor_vcpus[local.control_plane_instance_type] + local.worker_vcpus}"
    memory     = "pass 1: ${length(local.zones)} x ${local.jumphost_instance_type} (jumphost + builders) = ${try(length(local.zones) * local.flavor_memory_gb[local.jumphost_instance_type], "?")} GB; pass 2: 1 x ${local.jumphost_instance_type} + ${var.control_plane_count} x ${local.control_plane_instance_type}${local.worker_breakdown} = ${try(local.flavor_memory_gb[local.jumphost_instance_type] + var.control_plane_count * local.flavor_memory_gb[local.control_plane_instance_type] + local.worker_memory_gb, "?")} GB"
    public_ips = "API VIP + jumphost = 2, control planes = ${var.control_plane_public_ip ? var.control_plane_count : 0}, worker and GPU nodes = ${length([for n in local.agent_nodes : n if n.public_ip])}"
  }
}
