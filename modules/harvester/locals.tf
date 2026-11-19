# Shared RKE2 join token (kubernetes/config/{server,agent}.yaml).
# special = false: the value lands in a YAML scalar that nothing escapes.
resource "random_password" "token" {
  length  = 32
  special = false
}

# First-apply stamp for this cluster name; survives rebuilds and resizes.
resource "time_static" "created" {
  triggers = { cluster = var.cluster_name }
}

# Provider defaults for common variables (null means "use the default") and
# values that are constants on this provider.
locals {
  # Absolute, so the next_steps commands work from any directory. Uses the
  # cluster directory's link to the script (cluster.sh new) when there is one.
  cluster_dir = abspath(path.root)
  helper = { for s in ["kubeconfig", "ssh", "build-logs"] : s => (
    fileexists("${local.cluster_dir}/${s}.sh") ? "${local.cluster_dir}/${s}.sh" :
    "${abspath("${path.module}/../../scripts")}/${s}.sh -C ${local.cluster_dir}"
  ) }

  # Free-form label: Harvester has no regions.
  region = coalesce(var.region, "harvester")

  # vpc_cidr is required (checked in input_checks); the placeholder only keeps the other locals evaluable.
  vpc_cidr     = coalesce(var.vpc_cidr, "10.0.0.0/24")
  vpc_mtu      = coalesce(var.vpc_mtu, 1500)
  pod_veth_mtu = local.vpc_mtu - 50

  network_namespace = split("/", var.vpc_id)[0]
  network_name      = split("/", var.vpc_id)[1]

  control_plane_type    = coalesce(var.control_plane_instance_type, "8x32")
  control_plane_disk_gb = coalesce(var.control_plane_disk_size_gb, 100)
  agent_disk_gb         = 200
  buildhost_type        = coalesce(var.jumphost_instance_type, "4x8")
  buildhost_disk_gb     = coalesce(var.jumphost_disk_size_gb, 60)

  managed_labels = {
    "elemental-cluster"    = var.cluster_name
    "elemental-managed-by" = "terraform"
    "elemental-module"     = "ai-factory"
    "elemental-created"    = formatdate("YYYYMMDD-hhmmss", time_static.created.rfc3339)
  }
  # var.tags cannot use the managed prefix, so it never overrides these keys.
  labels = merge(local.managed_labels, var.tags)

  # MetalLB holds both VIPs (elemental-config, managed mode).
  api_vip_mode = "managed"
  # First boot takes 5-7 minutes; the build wait covers the package install, build and dd.
  image_build_timeout = 5400
  # Where cloud-init unpacks the Elemental config on the buildhost.
  config_dir = "/opt/elemental-config"
  # Directory the buildhost serves over HTTP; the image-factory hooks write the status file there.
  status_dir  = "/var/lib/image-factory/www"
  status_port = 8080
}

locals {
  api_host         = coalesce(var.api_host, "${var.api_vip}.sslip.io")
  rancher_hostname = coalesce(var.rancher_hostname, var.ingress_domain == null ? null : "rancher.${var.ingress_domain}", "rancher.${var.ingress_vip}.sslip.io")
}

# GPU and worker pools together: both are RKE2 agents built the same way.
# Pool keys are disjoint (validated in the common variables); role differs.
locals {
  agent_pools = merge(
    { for k, p in var.gpu_pools : k => merge(p, { role = "gpu" }) },
    { for k, p in var.worker_pools : k => merge(p, { role = "worker" }) },
  )
}

# Instance types: "<vcpu>x<memory_gib>". Parsed here, validated in terraform_data.input_checks.
locals {
  size_inputs = merge(
    {
      "buildhost"     = local.buildhost_type
      "control plane" = local.control_plane_type
    },
    {
      for k, p in local.agent_pools :
      "${p.role == "gpu" ? "GPU" : "worker"} pool \"${k}\"" => p.instance_type
    },
  )

  size_format = "^[1-9][0-9]*x[1-9][0-9]*$"

  size_errors = sort([
    for who, s in local.size_inputs : "${who} = \"${s}\" (expected \"<vcpu>x<memory_gib>\", for example \"8x32\")"
    if !can(regex(local.size_format, s))
  ])

  # Keyed by the instance type string as written; invalid ones parse to 0 (the plan fails on size_errors).
  sizes = {
    for s in distinct(values(local.size_inputs)) : s => {
      cpu    = can(regex(local.size_format, s)) ? tonumber(split("x", s)[0]) : 0
      memory = can(regex(local.size_format, s)) ? tonumber(split("x", s)[1]) : 0
    }
  }

  buildhost_size = local.sizes[local.buildhost_type]
}

# Image target volume size: image_disk_size (<N><K|M|G|T>) in whole GiB, at least 1.
locals {
  image_disk_n    = tonumber(regex("^[0-9]+", var.image_disk_size))
  image_disk_unit = regex("[KMGT]$", var.image_disk_size)
  image_disk_gib = max(1, (
    local.image_disk_unit == "T" ? local.image_disk_n * 1024 :
    local.image_disk_unit == "G" ? local.image_disk_n :
    ceil(local.image_disk_n / (local.image_disk_unit == "M" ? 1024 : 1048576))
  ))
}

# One image serves every node; role and init ride in per-node Ignition
# user_data. The list ignores deploy_nodes, so the image is the same.
locals {
  control_plane_nodes = [
    for i in range(var.control_plane_count) : {
      hostname = format("%s-cp-%02d", var.cluster_name, i + 1)
      pool     = "cp"
      role     = "control_plane"
      type     = "server"
      init     = i == 0

      who           = "control plane"
      instance_type = local.control_plane_type
      disk_size_gb  = local.control_plane_disk_gb
      gpu_key       = "cp"
    }
  ]

  # Sorted pool order; hostnames use the pool name and index, so changing one
  # pool never renames another.
  agent_nodes = flatten([
    for pool in sort(keys(local.agent_pools)) : [
      for i in range(local.agent_pools[pool].count) : {
        hostname = format("%s-%s-%02d", var.cluster_name, pool, i + 1)
        pool     = pool
        role     = local.agent_pools[pool].role
        type     = "agent"
        init     = false

        who           = "${local.agent_pools[pool].role == "gpu" ? "GPU" : "worker"} pool \"${pool}\""
        instance_type = local.agent_pools[pool].instance_type
        disk_size_gb  = coalesce(local.agent_pools[pool].disk_size_gb, local.agent_disk_gb)
        gpu_key       = local.agent_pools[pool].role == "gpu" ? pool : null
      }
    ]
  ])

  ignition_nodes = concat(local.control_plane_nodes, local.agent_nodes)

  # Host devices per node: <count> entries named gpu-1..gpu-N of the device of its gpu_key.
  node_host_devices = {
    for n in local.ignition_nodes : n.hostname => [
      for i in range(n.gpu_key != null ? try(var.gpu_devices[n.gpu_key].count, 0) : 0) : {
        name        = "gpu-${i + 1}"
        device_name = var.gpu_devices[n.gpu_key].device_name
      }
    ]
  }

  # Fixed MAC per VM, derived from the cluster and VM name: locally administered
  # (02:) and stable, so DHCP hands out the same address and a reservation can key on it.
  mac_hash = { for h in concat(["${var.cluster_name}-buildhost"], [for n in local.ignition_nodes : n.hostname]) : h => md5("${var.cluster_name}/${h}") }
  macs = {
    for h, d in local.mac_hash : h => format("02:%s:%s:%s:%s:%s",
      substr(d, 0, 2), substr(d, 2, 2), substr(d, 4, 2), substr(d, 6, 2), substr(d, 8, 2)
    )
  }
}

locals {
  # The target volume's StorageClass and access mode are immutable: changing
  # either needs a new build_id, hence a new volume name.
  extra_build_inputs = merge(
    { factory = module.image_factory.script_hash },
    var.storage_class_name == null ? {} : { storage_class = var.storage_class_name },
    local.target_access_mode == "ReadWriteMany" ? {} : { target_access_mode = local.target_access_mode },
  )
}
