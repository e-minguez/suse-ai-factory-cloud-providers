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

  # An Exoscale zone (de-fra-1 offers gpu3 and gpurtx6000pro).
  zone = coalesce(var.region, "de-fra-1")

  vpc_cidr    = coalesce(var.vpc_cidr, "10.20.0.0/20")
  vpc_network = cidrhost(local.vpc_cidr, 0)
  vpc_prefix  = tonumber(split("/", local.vpc_cidr)[1])
  vpc_mtu     = coalesce(var.vpc_mtu, 1500)

  # The jumphost takes a static lease below the DHCP range; every other node
  # gets a dynamic lease.
  jumphost_private_ip = cidrhost(local.vpc_cidr, 5)
  dhcp_start_ip       = cidrhost(local.vpc_cidr, 10)
  dhcp_end_ip         = cidrhost(local.vpc_cidr, -3)

  control_plane_type    = coalesce(var.control_plane_instance_type, "standard.extra-large")
  control_plane_disk_gb = coalesce(var.control_plane_disk_size_gb, 100)
  agent_disk_gb         = 200
  jumphost_type         = coalesce(var.jumphost_instance_type, "standard.large")
  jumphost_disk_gb      = coalesce(var.jumphost_disk_size_gb, 50)
  jumphost_template     = coalesce(var.jumphost_image, "OpenSUSE Leap 16.0 64-bit")

  managed_labels = {
    "elemental-cluster"    = var.cluster_name
    "elemental-managed-by" = "terraform"
    "elemental-module"     = "ai-factory"
    "elemental-created"    = formatdate("YYYYMMDD-hhmmss", time_static.created.rfc3339)
  }
  # var.tags cannot use the managed prefix, so it never overrides these keys.
  labels = merge(local.managed_labels, var.tags)

  api_vip_mode        = "external"
  image_build_timeout = 5400
  image_serve_seconds = 3600
  # Exoscale templates need a qcow2 virtual size of 10-1000 GB.
  template_min_gib = 10
  # Seconds a node waits for its privnet address (pool NICs are hot-plugged).
  privnet_wait_seconds = 300
}

locals {
  api_vip = exoscale_nlb.this.ip_address

  # Rancher answers on the NLB's ingress services; without an ingress controller
  # the chart still needs a hostname, so the same address is used.
  rancher_hostname = coalesce(var.rancher_hostname, "rancher-${local.api_vip}.sslip.io")
  api_host         = coalesce(var.api_host, "rke2-${local.api_vip}.sslip.io")
}

# Where the cloud-init payload is unpacked on the jumphost, and the -v mount
# point for `podman run ... customize --local`.
locals {
  config_dir = "/opt/elemental-config"
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
  # Regex pinning canal VXLAN to the privnet NIC, from the octets the prefix
  # fixes (a /20 gives "^10\.20\.").
  vpc_iface_regex_octets = local.vpc_prefix >= 24 ? 3 : (local.vpc_prefix >= 16 ? 2 : 1)
  vpc_iface_regex        = "^${join("\\.", slice(split(".", local.vpc_network), 0, local.vpc_iface_regex_octets))}\\."

  # VXLAN adds 50 bytes; calico sizes pod veths from this value.
  pod_veth_mtu = local.vpc_mtu - 50

  # The control planes are one instance pool and share one Ignition entry: its
  # hostname is a placeholder that node-hostname.service replaces with the
  # member name. Only the first member, alone in the pool, initializes the
  # cluster (docs/decisions/008-exoscale-module.md).
  control_plane_prefix = "${var.cluster_name}-cp"
  control_plane_entry = {
    hostname = local.control_plane_prefix
    pool     = "cp"
    role     = "control_plane"
    type     = "server"
    init     = !var.cp_initialized
  }
  control_plane_size = var.cp_initialized ? var.control_plane_count : 1

  # Sorted pool order; hostnames use the pool name and index, so changing one
  # pool never renames another.
  agent_nodes = flatten([
    for pool in sort(keys(local.agent_pools)) : [
      for i in range(local.agent_pools[pool].count) : {
        hostname      = format("%s-%s-%02d", var.cluster_name, pool, i + 1)
        pool          = pool
        role          = local.agent_pools[pool].role
        type          = "agent"
        init          = false
        instance_type = local.agent_pools[pool].instance_type
        disk_size_gb  = coalesce(local.agent_pools[pool].disk_size_gb, local.agent_disk_gb)
      }
    ]
  ])

  ignition_nodes = concat([local.control_plane_entry], local.agent_nodes)
}

# The factory script feeds build_hash, so values derived from the hash are
# placeholders substituted afterwards.
locals {
  build_id_placeholder   = "@@BUILD_ID@@"
  serve_path_placeholder = "@@SERVE_PATH@@"
  image_base_placeholder = "${var.cluster_name}-${local.build_id_placeholder}"

  factory_script = replace(
    replace(
      replace(module.image_factory.script_stripped, local.image_base_placeholder, local.image_base),
      local.serve_path_placeholder, random_id.serve_path.hex
    ),
    local.build_id_placeholder, module.config.build_id
  )
}
