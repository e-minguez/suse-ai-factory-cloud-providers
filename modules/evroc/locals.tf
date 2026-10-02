# Shared RKE2 join token, used by kubernetes/config/{server,agent}.yaml.
# special = false: the value lands verbatim in a YAML scalar in the elemental
# config dir, where a special character would need escaping nobody would add.
resource "random_password" "token" {
  length  = 32
  special = false
}

# Provider defaults for common variables left null, and fixed platform values.
locals {
  # Absolute, so the next_steps commands work from any directory. Uses the
  # cluster directory's link to the script (cluster.sh new) when there is one.
  cluster_dir = abspath(path.root)
  helper = { for s in ["kubeconfig", "ssh", "build-logs"] : s => (
    fileexists("${local.cluster_dir}/${s}.sh") ? "${local.cluster_dir}/${s}.sh" :
    "${abspath("${path.module}/../../scripts")}/${s}.sh -C ${local.cluster_dir}"
  ) }

  zones                       = length(var.zones) > 0 ? var.zones : ["a", "b", "c"]
  vpc_cidr                    = coalesce(var.vpc_cidr, "10.20.0.0/16")
  vpc_mtu                     = coalesce(var.vpc_mtu, 8900)
  control_plane_instance_type = coalesce(var.control_plane_instance_type, "c1a.m")
  control_plane_disk_size_gb  = coalesce(var.control_plane_disk_size_gb, 200)
  jumphost_instance_type      = coalesce(var.jumphost_instance_type, "a1a.m")
  jumphost_disk_size_gb       = coalesce(var.jumphost_disk_size_gb, 200)

  # Zones where the platform admits GPU VMs (virtualmachine-webhook.evroc.com).
  gpu_zones = ["a"]

  # Bits added to vpc_cidr's prefix for each zone's subnet (/16 -> /20).
  subnet_newbits = 4

  api_vip_mode        = "external"
  disk_create_timeout = "30m"
  disk_delete_timeout = "20m"
  # Seconds wait-for-image.sh polls the status relay before giving up.
  image_build_timeout = 5400
  status_relay_port   = 8080
}

# First-apply stamp for this cluster name; survives rebuilds and resizes.
# Not tied to build_id: the VIP wears these labels (see common_labels).
resource "time_static" "created" {
  triggers = { cluster = var.cluster_name }
}

locals {
  # Labels on every evroc object; resources add role (and pool, listener).
  # No build id here (it would cycle through the VIP). var.tags: no elemental-
  # prefix, no "/" in keys (network.tf). See docs/decisions/004-evroc-module-rationale.md.
  common_labels = merge({
    "elemental-cluster"    = var.cluster_name
    "elemental-managed-by" = "terraform"
    "elemental-module"     = "ai-factory"
    "elemental-created"    = formatdate("YYYYMMDD-hhmmss", time_static.created.rfc3339)
  }, var.tags)

  # common_labels plus the image generation, for objects whose content comes
  # from one build (image-target disks, node disks and nodes). Not applied to
  # objects that survive a rebuild.
  build_labels = merge(local.common_labels, { "elemental-build" = local.build_id })

  # Where the cloud-init payload is unpacked on the jumphost; mounted with -v
  # into `podman run ... customize --type raw` (no --local, see modules/image-factory).
  config_dir = "/opt/elemental-config"
}

# api_vip is baked into every node's elemental config, so evroc_public_ip.cluster
# has no dependencies (network.tf).
locals {
  api_vip = evroc_public_ip.cluster.ip_address

  api_host = coalesce(var.api_host, "rke2-${local.api_vip}.sslip.io")

  # Rancher's ingress and the Kubernetes API share the load balancer's one
  # public IP (loadbalancer.tf).
  rancher_hostname = coalesce(var.rancher_hostname, "rancher-${local.api_vip}.sslip.io")
}

# Queried live so the jumphost image tracks what evroc offers. Leap 15.6 is the
# newest Leap available.
data "evroc_disk_images" "this" {}

locals {
  jumphost_image = coalesce(var.jumphost_image, data.evroc_disk_images.this.opensuse_15_6_1)
}

# One image serves every node; hostname and RKE2 role ride per node in Ignition
# user_data (module.config.node_runtime_ignition). Every VM has one NIC.
locals {
  # One subnet CIDR per zone, carved from vpc_cidr in zone-list order and
  # exported as the subnet_cidrs output.
  #
  # The index is the zone's position in local.zones: append zones, do not reorder.
  subnet_cidrs = {
    for i, z in local.zones : z => cidrsubnet(local.vpc_cidr, local.subnet_newbits, i)
  }

  # Every subnet shares this prefix length by construction, which is what lets
  # configure-network.sh -- one script baked into one image serving nodes in
  # every zone -- state a single expected prefix.
  subnet_prefix = tonumber(split("/", local.vpc_cidr)[1]) + local.subnet_newbits

  # Snapshots are zonal, so the image is built once per zone (build.tf).
  # See docs/decisions/004-evroc-module-rationale.md.

  # The zone whose jumphost has the public IP; other build hosts are reached
  # through it (scripts/wait-for-image.sh).
  primary_zone = local.zones[0]

  # Flannel --iface-regex pinning canal VXLAN to the VPC NIC. Built from the
  # constant octets of vpc_cidr, the only range common to every zone's subnet
  # (a /16 yields "^10\.20\.").
  vpc_iface_regex_octets = tonumber(split("/", local.vpc_cidr)[1]) >= 24 ? 3 : (tonumber(split("/", local.vpc_cidr)[1]) >= 16 ? 2 : 1)
  vpc_iface_regex        = "^${join("\\.", slice(split(".", split("/", local.vpc_cidr)[0]), 0, local.vpc_iface_regex_octets))}\\."

  # Calico sizes pod veths without knowing the underlay: subtract 50 bytes of VXLAN.
  pod_veth_mtu = local.vpc_mtu - 50

  # Zones are assigned round-robin by node index, so a larger control_plane_count
  # only appends nodes (moving an etcd member recreates it). cp-01 initializes
  # the cluster; IS_INIT_NODE rides in module.config.node_runtime_ignition.
  control_plane_nodes = [
    for i in range(var.control_plane_count) : {
      hostname = format("%s-cp-%02d", var.cluster_name, i + 1)
      pool     = "cp"
      role     = "control_plane"
      type     = "server"
      init     = i == 0
      zone     = local.zones[i % length(local.zones)]
    }
  ]

  # Worker and GPU pools share one code path (agent-nodes.tf); role tells them apart.
  agent_pools = merge(
    { for k, v in var.worker_pools : k => merge(v, { role = "worker" }) },
    { for k, v in var.gpu_pools : k => merge(v, { role = "gpu" }) },
  )

  # One entry per agent node. Sorted by pool key and indexed per pool, so
  # changing one pool never renames another's nodes. Zone is the pool's own,
  # else zones[0]; disk size defaults to the control-plane disk size.
  agent_nodes = flatten([
    for pool in sort(keys(local.agent_pools)) : [
      for i in range(local.agent_pools[pool].count) : {
        hostname      = format("%s-%s-%02d", var.cluster_name, pool, i + 1)
        pool          = pool
        role          = local.agent_pools[pool].role
        type          = "agent"
        instance_type = local.agent_pools[pool].instance_type
        zone          = coalesce(local.agent_pools[pool].zone, local.zones[0])
        disk_size_gb  = coalesce(local.agent_pools[pool].disk_size_gb, local.control_plane_disk_size_gb)
        public_ip     = local.agent_pools[pool].public_ip
      }
    ]
  ])

  # One placement group per pool that sets `placement` and has nodes (a pool
  # is in one zone). Keyed "<pool>/<zone>"; agent-nodes.tf rebuilds the key per node.
  agent_placement_groups = {
    for pool, p in local.agent_pools :
    "${pool}/${coalesce(p.zone, local.zones[0])}" => {
      pool     = pool
      role     = p.role
      zone     = coalesce(p.zone, local.zones[0])
      strategy = p.placement
    }
    if p.placement != null && p.count > 0
  }

  cluster_nodes = concat(local.control_plane_nodes, local.agent_nodes)
}

# Build-host script per zone: the image-factory module plus evroc hooks. Must not
# read evroc computed attributes; build id and zone are substituted after hashing.
locals {
  # Blank disk the image is written onto, one per zone; always zone-suffixed so
  # adding a zone does not rename the first disk.
  image_target_disk_names = {
    for z in local.zones : z => "${var.cluster_name}-image-target-${z}"
  }

  build_id_placeholder = "@@BUILD_ID@@"

  zone_placeholder = "@@ZONE@@"
}

# script_hash covers the zone-independent script and feeds build_hash.
locals {
  factory_script = {
    for z in local.zones : z => replace(
      replace(module.image_factory.script_stripped, local.zone_placeholder, z),
      local.build_id_placeholder, local.build_id
    )
  }
}
