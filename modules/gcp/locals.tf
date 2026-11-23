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

data "google_client_config" "this" {}

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

  # A Google Cloud region; europe-west4 offers L4 and RTX PRO 6000 GPUs in zones a, b and c.
  region = coalesce(var.region, "europe-west4")

  # An existing subnet (subnet_id) supplies its own primary range.
  vpc_cidr = local.create_network ? coalesce(var.vpc_cidr, "10.20.0.0/20") : try(data.google_compute_subnetwork.existing[0].ip_cidr_range, coalesce(var.vpc_cidr, "10.20.0.0/20"))
  # A custom-mode VPC defaults to 1460; the platform accepts 1300-8896. The MTU of
  # an existing network cannot be read: set vpc_mtu to it when it is not 1460.
  vpc_mtu      = coalesce(var.vpc_mtu, 1460)
  pod_veth_mtu = local.vpc_mtu - 50
  vpc_prefix   = tonumber(split("/", local.vpc_cidr)[1])

  control_plane_type    = coalesce(var.control_plane_instance_type, "n2-standard-4")
  control_plane_disk_gb = coalesce(var.control_plane_disk_size_gb, 100)
  agent_disk_gb         = 200
  jumphost_type         = coalesce(var.jumphost_instance_type, "e2-standard-4")
  jumphost_disk_gb      = coalesce(var.jumphost_disk_size_gb, 100)

  # Latest openSUSE Leap from the public image project (family resolved at creation).
  jumphost_image = coalesce(var.jumphost_image, "projects/opensuse-cloud/global/images/family/opensuse-leap")

  # GCP label keys and values: lowercase letters, digits, "_" and "-"; keys start with a letter.
  managed_labels = {
    "elemental-cluster"    = var.cluster_name
    "elemental-managed-by" = "terraform"
    "elemental-module"     = "ai-factory"
    "elemental-created"    = formatdate("YYYYMMDD-hhmmss", time_static.created.rfc3339)
  }
  # var.tags cannot use the managed prefix, so it never overrides these keys.
  labels = merge(local.managed_labels, var.tags)

  api_vip_mode = "external"
  # The jumphost reports through guest attributes; this is the upper bound of the wait.
  image_build_timeout = 5400
  # Where the startup script unpacks the Elemental config on the jumphost.
  config_dir = "/opt/elemental-config"

  # Raw image size in GiB (image_disk_size is <integer><K|M|G|T>); the blank target disk is as large.
  image_target_gb = ceil(
    tonumber(substr(var.image_disk_size, 0, length(var.image_disk_size) - 1)) *
    lookup({ K = 1 / 1048576, M = 1 / 1024, G = 1, T = 1024 }, substr(var.image_disk_size, -1, 1), 1)
  )
}

# Zones are full names ("europe-west4-a"); the default is the first zone of the region.
data "google_compute_zones" "region" {
  region = local.region
  status = "UP"
}

locals {
  zones      = length(var.zones) > 0 ? var.zones : ["${local.region}-a"]
  zone_set   = toset(local.zones)
  zone_count = length(local.zones)
}

locals {
  # Reserved before the image: both addresses are in it (api_vip, api_host, local routes).
  api_vip          = google_compute_address.internal_lb.address
  external_address = google_compute_address.external_lb.address

  # Rancher answers on the external load balancer's ingress listeners; without
  # an ingress controller the chart still needs a hostname, so the same address is used.
  rancher_hostname = coalesce(var.rancher_hostname, var.ingress_domain == null ? null : "rancher.${var.ingress_domain}", "rancher-${local.external_address}.sslip.io")
  api_host         = coalesce(var.api_host, "rke2-${local.external_address}.sslip.io")
}

# GPU and worker pools together: both are RKE2 agents built the same way.
# Pool keys are disjoint (validated in the common variables); role differs.
locals {
  agent_pools = merge(
    { for k, p in var.gpu_pools : k => merge(p, { role = "gpu" }) },
    { for k, p in var.worker_pools : k => merge(p, { role = "worker" }) },
  )
}

# Machine type facts, from the type name only: family, boot disk type and
# interface, and whether the family needs TERMINATE on host maintenance.
locals {
  # Disk and interface by family. Hyperdisk-only and NVMe-only families are the
  # third generation and later (they also require gVNIC); the rest boots from pd-balanced.
  hyperdisk_families = ["c3", "c3d", "c4", "c4a", "c4d", "n4", "g4", "a3", "a4", "a4x"]
  nvme_families      = ["c3", "c3d", "c4", "c4a", "c4d", "n4", "g2", "g4", "a3", "a4", "a4x"]
  gpu_families       = ["g2", "g4", "a2", "a3", "a4", "a4x"]

  machine_type_names = distinct(concat(
    [local.jumphost_type, local.control_plane_type],
    [for k, p in local.agent_pools : p.instance_type],
  ))

  machine_family = { for t in local.machine_type_names : t => split("-", t)[0] }

  machine_type_format = "^[a-z][a-z0-9]*-[a-z0-9-]+$"
  # G4 fractional sizes (1/8, 1/4 and 1/2 GPU) need the vGPU driver path.
  fractional_g4 = "^g4-standard-(6|12|24)$"

  machine_type_errors = sort(flatten([
    for who, t in merge(
      { "jumphost" = local.jumphost_type, "control plane" = local.control_plane_type },
      { for k, p in local.agent_pools : "${p.role == "gpu" ? "GPU" : "worker"} pool \"${k}\"" => p.instance_type },
      ) : (
      !can(regex(local.machine_type_format, t)) ? ["${who} = \"${t}\" (expected a machine type such as \"n2-standard-4\" or \"g2-standard-4\")"] :
      can(regex(local.fractional_g4, t)) ? ["${who} = \"${t}\" (fractional G4 sizes are not supported: use g4-standard-48 or larger)"] :
      strcontains(t, ":") ? ["${who} = \"${t}\" (machine types take no suffix; accelerators come with the machine type)"] :
      []
    )
  ]))

  boot_disk_type = {
    for t in local.machine_type_names : t => contains(local.hyperdisk_families, local.machine_family[t]) ? "hyperdisk-balanced" : "pd-balanced"
  }
  # Cluster nodes only; the jumphost keeps the family default.
  node_boot_disk_type = {
    for t in local.machine_type_names : t => coalesce(var.boot_disk_type, local.boot_disk_type[t])
  }
  boot_disk_interface = {
    for t in local.machine_type_names : t => contains(local.nvme_families, local.machine_family[t]) ? "NVME" : null
  }
}

# One image serves every node; role and init ride in per-node Ignition
# user_data. The list ignores deploy_nodes, so the image is the same.
locals {
  # Control planes go round-robin over the zones.
  control_plane_nodes = [
    for i in range(var.control_plane_count) : {
      hostname = format("%s-cp-%02d", var.cluster_name, i + 1)
      pool     = "cp"
      role     = "control_plane"
      type     = "server"
      init     = i == 0

      who           = "control plane"
      instance_type = local.control_plane_type
      zone          = local.zones[i % local.zone_count]
      disk_size_gb  = local.control_plane_disk_gb
      public_ip     = var.control_plane_public_ip
    }
  ]

  # Sorted pool order; hostnames use the pool name and index, so changing one
  # pool never renames another. A pool without zone spreads over every zone.
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
        zone          = local.agent_pools[pool].zone != null ? local.agent_pools[pool].zone : local.zones[i % local.zone_count]
        disk_size_gb  = coalesce(local.agent_pools[pool].disk_size_gb, local.agent_disk_gb)
        public_ip     = local.agent_pools[pool].public_ip
      }
    ]
  ])

  ignition_nodes = concat(local.control_plane_nodes, local.agent_nodes)
}
