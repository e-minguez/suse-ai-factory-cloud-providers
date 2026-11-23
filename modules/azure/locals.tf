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

  # An Azure location name ("westeurope"); "West Europe" is accepted and normalised.
  region = lower(replace(coalesce(var.region, "westeurope"), " ", ""))

  vpc_cidr_new = coalesce(var.vpc_cidr, "10.20.0.0/20")
  # An existing virtual network (vpc_id) without vpc_cidr uses its first address space.
  vpc_cidr = local.create_network || var.vpc_cidr != null ? local.vpc_cidr_new : try(data.azurerm_virtual_network.existing[0].address_space[0], local.vpc_cidr_new)
  # A virtual network carries 1500-byte frames unless the MTU is raised on the network.
  vpc_mtu      = coalesce(var.vpc_mtu, 1500)
  pod_veth_mtu = local.vpc_mtu - 50
  vpc_prefix   = tonumber(split("/", local.vpc_cidr)[1])

  # Created network: low half public subnet (jumphost), high half private subnet (nodes).
  public_subnet_cidr  = local.create_network ? cidrsubnet(local.vpc_cidr, 1, 0) : try(local.existing_subnets["public"].cidr, null)
  private_subnet_cidr = local.create_network ? cidrsubnet(local.vpc_cidr, 1, 1) : try(local.existing_subnets["private"].cidr, null)

  control_plane_type    = coalesce(var.control_plane_instance_type, "Standard_D8s_v5")
  control_plane_disk_gb = coalesce(var.control_plane_disk_size_gb, 100)
  agent_disk_gb         = 200
  jumphost_type         = coalesce(var.jumphost_instance_type, "Standard_D4s_v5")
  jumphost_disk_gb      = coalesce(var.jumphost_disk_size_gb, 100)
  os_disk_type          = "Premium_LRS"

  # publisher:offer:sku:version; version may be "latest".
  jumphost_image      = coalesce(var.jumphost_image, "SUSE:sles-16-0-x86-64:gen2:latest")
  jumphost_image_ref  = try(zipmap(["publisher", "offer", "sku", "version"], split(":", local.jumphost_image)), null)
  jumphost_admin_user = var.jumphost_username != "" ? var.jumphost_username : "azureuser"

  # Admin account names the platform rejects (the VM resource requires one).
  reserved_usernames = ["root", "admin", "administrator", "guest", "test", "user", "sa", "sys", "owner", "server", "backup", "console", "support", "sql"]

  managed_labels = {
    "elemental-cluster"    = var.cluster_name
    "elemental-managed-by" = "terraform"
    "elemental-module"     = "ai-factory"
    "elemental-created"    = formatdate("YYYYMMDD-hhmmss", time_static.created.rfc3339)
  }
  # var.tags cannot use the managed prefix, so it never overrides these keys.
  labels = merge(local.managed_labels, var.tags)

  api_vip_mode = "external"
  # The upload is the long part; the gallery replication runs inside the resource timeout.
  image_build_timeout = 5400
  # A SAS token must outlive the build (90 minutes at most) with a margin.
  sas_expiry_hours = 6
  # Where cloud-init unpacks the Elemental config on the jumphost.
  config_dir = "/opt/elemental-config"
}

locals {
  api_vip = azurerm_public_ip.lb.ip_address

  # Rancher answers on the load balancer's ingress rules; without an ingress
  # controller the chart still needs a hostname, so the same address is used.
  rancher_hostname = coalesce(var.rancher_hostname, var.ingress_domain == null ? null : "rancher.${var.ingress_domain}", "rancher-${local.api_vip}.sslip.io")
  api_host         = coalesce(var.api_host, "rke2-${local.api_vip}.sslip.io")
}

# GPU and worker pools together: both are RKE2 agents built the same way.
# Pool keys are disjoint (validated in the common variables); role differs.
locals {
  agent_pools = merge(
    { for k, p in var.gpu_pools : k => merge(p, { role = "gpu" }) },
    { for k, p in var.worker_pools : k => merge(p, { role = "worker" }) },
  )
}

# One image serves every node; role and init ride in per-node Ignition
# user_data. The list ignores deploy_nodes, so the image is the same.
locals {
  # Zones in use: var.zones, else the region's zones (availability.tf). A
  # region without zones gives [], and nodes are not pinned.
  zone_rr    = length(local.zones) > 0 ? local.zones : [null]
  zone_count = length(local.zone_rr)

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
      zone          = local.zone_rr[i % local.zone_count]
      disk_size_gb  = local.control_plane_disk_gb
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
        zone          = local.agent_pools[pool].zone != null ? local.agent_pools[pool].zone : local.zone_rr[i % local.zone_count]
        disk_size_gb  = coalesce(local.agent_pools[pool].disk_size_gb, local.agent_disk_gb)
      }
    ]
  ])

  ignition_nodes = concat(local.control_plane_nodes, local.agent_nodes)
}
