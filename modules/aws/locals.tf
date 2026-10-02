# Shared RKE2 join token. special = false keeps the value a plain YAML scalar.
resource "random_password" "token" {
  length  = 32
  special = false
}

# Provider defaults for common variables that default to null.
locals {
  # Absolute, so the next_steps commands work from any directory. Uses the
  # cluster directory's link to the script (cluster.sh new) when there is one.
  cluster_dir = abspath(path.root)
  helper = { for s in ["kubeconfig", "ssh", "build-logs"] : s => (
    fileexists("${local.cluster_dir}/${s}.sh") ? "${local.cluster_dir}/${s}.sh" :
    "${abspath("${path.module}/../../scripts")}/${s}.sh -C ${local.cluster_dir}"
  ) }

  config_dir = "/opt/elemental-config"

  vpc_cidr                    = coalesce(var.vpc_cidr, "10.20.0.0/20")
  vpc_mtu                     = coalesce(var.vpc_mtu, 9001)
  pod_veth_mtu                = local.vpc_mtu - 50
  control_plane_instance_type = coalesce(var.control_plane_instance_type, "m7i.xlarge")
  control_plane_disk_size_gb  = coalesce(var.control_plane_disk_size_gb, 100)
  jumphost_instance_type      = coalesce(var.jumphost_instance_type, "c6i.xlarge")
  jumphost_disk_size_gb       = coalesce(var.jumphost_disk_size_gb, 100)

  # Empty zones: the first three AZs of the region. Suffixes are relative to var.region.
  zones = length(var.zones) > 0 ? var.zones : [
    for n in slice(data.aws_availability_zones.available.names, 0, min(3, length(data.aws_availability_zones.available.names))) :
    trimprefix(n, coalesce(var.region, ""))
  ]
  az_names = [for z in local.zones : "${var.region}${z}"]
  az_count = length(local.zones)

  # Pool zone defaults to the first zone; disk to 200 GB. role is the node kind (nodes[*].role).
  worker_pools = {
    for k, p in var.worker_pools : k => merge(p, {
      role         = "worker"
      disk_size_gb = coalesce(p.disk_size_gb, 200)
      zone         = coalesce(p.zone, local.zones[0])
    })
  }
  gpu_pools = {
    for k, p in var.gpu_pools : k => merge(p, {
      role         = "gpu"
      disk_size_gb = coalesce(p.disk_size_gb, 200)
      zone         = coalesce(p.zone, local.zones[0])
    })
  }
  # Keys are disjoint (variable validation).
  agent_pools     = merge(local.worker_pools, local.gpu_pools)
  has_agent_pools = length(local.agent_pools) > 0
}

# Networking: every address is chosen at plan time, so the image, load
# balancers and nodes need no second apply.
locals {
  # Each half of the VPC (low = public, high = private) is split into one subnet per zone.
  az_bits       = local.az_count <= 1 ? 0 : ceil(log(local.az_count, 2))
  public_block  = cidrsubnet(local.vpc_cidr, 1, 0)
  private_block = cidrsubnet(local.vpc_cidr, 1, 1)

  public_subnet_cidrs  = [for i in range(local.az_count) : cidrsubnet(local.public_block, local.az_bits, i)]
  private_subnet_cidrs = [for i in range(local.az_count) : cidrsubnet(local.private_block, local.az_bits, i)]

  # Host 10 of the first private subnet: the internal NLB's static address and network.apiVIP.
  api_vip  = cidrhost(local.private_subnet_cidrs[0], 10)
  api_host = coalesce(var.api_host, aws_lb.api.dns_name)
  # Outputs and kubeconfig: the public NLB serves kubectl on 6443 to api_cidrs and
  # is in the SANs. Nodes keep api_host above (internal NLB) in their config.
  admin_api_host = coalesce(var.api_host, aws_lb.public.dns_name)

  # Null rancher_hostname falls back to the public NLB DNS name.
  rancher_hostname = coalesce(var.rancher_hostname, aws_lb.public.dns_name)
}

# Node model: identity, placement and address.
locals {
  control_plane_nodes_raw = [
    for i in range(var.control_plane_count) : {
      hostname      = format("%s-cp-%02d", var.cluster_name, i + 1)
      pool          = "cp"
      instance_type = local.control_plane_instance_type
      role          = "control_plane"
      type          = "server"
      init          = i == 0 # cp-01 initializes the cluster; the rest join it.
      az_index      = i % local.az_count
      disk_size_gb  = local.control_plane_disk_size_gb
    }
  ]

  # Worker and GPU pools in sort(keys()) order so hostnames stay stable when other pools change.
  # A zone outside local.zones maps to index 0 here; the aws_vpc.this preconditions reject it.
  agent_nodes_raw = flatten([
    for pool in sort(keys(local.agent_pools)) : [
      for i in range(local.agent_pools[pool].count) : {
        hostname      = format("%s-%s-%02d", var.cluster_name, pool, i + 1)
        pool          = pool
        instance_type = local.agent_pools[pool].instance_type
        role          = local.agent_pools[pool].role
        type          = "agent"
        init          = false
        az_index      = max(try(index(local.zones, local.agent_pools[pool].zone), -1), 0)
        disk_size_gb  = local.agent_pools[pool].disk_size_gb
      }
    ]
  ])

  cluster_nodes_raw = concat(local.control_plane_nodes_raw, local.agent_nodes_raw)

  # Hosts 20+ of each private subnet; the platform reserves the first four and the last address.
  node_ip_base_offset = 20

  # Control planes get a fixed IP (load balancer targets): position among earlier
  # control planes in the same zone. Agents take a DHCP address, so adding pools
  # or control planes never shifts them.
  cluster_nodes = [
    for idx, node in local.cluster_nodes_raw : merge(node, {
      subnet_index = node.az_index
      private_ip = node.role != "control_plane" ? null : cidrhost(
        local.private_subnet_cidrs[node.az_index],
        local.node_ip_base_offset + length([
          for earlier in slice(local.cluster_nodes_raw, 0, idx) : earlier if earlier.az_index == node.az_index
        ])
      )
    })
  ]

  control_plane_nodes = [for n in local.cluster_nodes : n if n.role == "control_plane"]
  agent_nodes         = [for n in local.cluster_nodes : n if n.role != "control_plane"]
}

locals {
  ami_name = "${var.cluster_name}-${module.elemental_config.build_id}"

  # image_id skips the build/import/register chain (image.tf); try() because aws_ami.ai_factory has count = 0 then.
  effective_ami_id = var.image_id != null ? var.image_id : try(aws_ami.ai_factory[0].id, null)
}

# First-apply stamp for this cluster name; survives rebuilds and resizes. It
# must not depend on build_id or the load balancers (cycle through common_tags).
resource "time_static" "created" {
  triggers = { cluster = var.cluster_name }
}

locals {
  # The build label is added per resource: build_id depends on the load
  # balancer DNS names, and the load balancers read common_tags.
  managed_tags = {
    "elemental-cluster"    = var.cluster_name
    "elemental-managed-by" = "terraform"
    "elemental-module"     = "ai-factory"
    "elemental-created"    = formatdate("YYYYMMDD-hhmmss", time_static.created.rfc3339)
  }

  # var.tags cannot use the elemental- prefix (validated), so it never overrides these.
  common_tags = merge(local.managed_tags, var.tags)
}
