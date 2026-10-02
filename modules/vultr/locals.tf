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

  vpc_cidr    = coalesce(var.vpc_cidr, "10.20.0.0/20")
  vpc_network = cidrhost(local.vpc_cidr, 0)
  vpc_prefix  = tonumber(split("/", local.vpc_cidr)[1])
  vpc_mtu     = coalesce(var.vpc_mtu, 1450)

  control_plane_plan = coalesce(var.control_plane_instance_type, "vx1-g-4c-16g-240s")
  jumphost_plan      = coalesce(var.jumphost_instance_type, "vc2-6c-16gb")
  jumphost_os_id     = tonumber(coalesce(var.jumphost_image, "2656"))

  # The provider takes tags as a list, so labels become "key=value" strings.
  # var.tags cannot use the managed prefix, so it never overrides these keys.
  jumphost_tags = [for k, v in merge(local.managed_tags, { "elemental-role" = "jumphost" }, var.tags) : "${k}=${v}"]
  node_tags = {
    for n in local.cluster_nodes : n.hostname => [
      for k, v in merge(local.managed_tags, {
        "elemental-role"  = n.role
        "elemental-pool"  = n.pool
        "elemental-build" = module.config.build_id
      }, var.tags) : "${k}=${v}"
    ]
  }
  managed_tags = {
    "elemental-cluster"    = var.cluster_name
    "elemental-managed-by" = "terraform"
    "elemental-module"     = "ai-factory"
    "elemental-created"    = formatdate("YYYYMMDD-hhmmss", time_static.created.rfc3339)
  }

  lb_nodes            = 1
  api_vip_mode        = "external"
  image_build_timeout = 5400
  image_serve_seconds = 3600
  enable_ipv6         = false
  activation_email    = false
  dns_servers         = ["108.61.10.10", "8.8.8.8"]
}

locals {
  # null unless ingress_controller = "traefik".
  ingress_lb_ipv4 = lookup(local.lb_ipv4, "ingress", null)

  # Rancher answers on the ingress LB; without an ingress controller it falls
  # back to the API address, because the chart requires a hostname.
  rancher_hostname = coalesce(var.rancher_hostname, "rancher-${coalesce(local.ingress_lb_ipv4, local.api_vip)}.sslip.io")

  api_host = coalesce(var.api_host, "rke2-${local.api_vip}.sslip.io")
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

# One image serves every node; hostname and role ride in per-node Ignition
# user_data. The list ignores deploy_nodes, so the image is the same.
locals {
  # Regex pinning canal VXLAN to the VPC NIC, from the octets the prefix fixes
  # (a /20 gives "^10\.20\.").
  vpc_iface_regex_octets = local.vpc_prefix >= 24 ? 3 : (local.vpc_prefix >= 16 ? 2 : 1)
  vpc_iface_regex        = "^${join("\\.", slice(split(".", local.vpc_network), 0, local.vpc_iface_regex_octets))}\\."

  # VXLAN adds 50 bytes; calico sizes pod veths from this value.
  pod_veth_mtu = local.vpc_mtu - 50

  # public_nic tells write-node-ip.sh and configure-network.sh whether the node
  # has a public NIC.
  control_plane_nodes = [
    for i in range(var.control_plane_count) : {
      hostname   = format("%s-cp-%02d", var.cluster_name, i + 1)
      pool       = "cp"
      role       = "control_plane"
      plan       = local.control_plane_plan
      family     = "control-plane"
      type       = "server"
      init       = i == 0 # cp-01 initializes the cluster; the rest join it.
      public_nic = false
    }
  ]

  # Bare metal first, then cloud, in sorted pool order. Hostnames use the pool
  # name and index, so changing one pool never renames another. A cloud pool
  # without public_ip is vpc_only; bare metal always has a public NIC.
  agent_nodes = [
    for n in flatten([
      for kind in ["bare_metal", "vm"] : [
        for pool in sort(keys(local.agent_pools)) : [
          for i in range(local.agent_pools[pool].count) : {
            hostname = format("%s-%s-%02d", var.cluster_name, pool, i + 1)
            pool     = pool
            plan     = local.agent_pools[pool].instance_type
            role     = local.agent_pools[pool].role
            kind     = kind
            vpc_only = kind == "vm" && !local.agent_pools[pool].public_ip
          }
        ] if local.agent_pools[pool].kind == kind
      ]
      ]) : {
      hostname   = n.hostname
      pool       = n.pool
      plan       = n.plan
      role       = n.role
      kind       = n.kind
      family     = n.kind == "bare_metal" ? "bare-metal" : "cloud"
      type       = "agent"
      init       = false
      vpc_only   = n.vpc_only
      public_nic = !n.vpc_only
    }
  ]

  agent_bare_metal_nodes = [for n in local.agent_nodes : n if n.kind == "bare_metal"]
  agent_cloud_nodes      = [for n in local.agent_nodes : n if n.kind == "vm"]

  cluster_nodes = concat(local.control_plane_nodes, local.agent_nodes)
}

# The factory script feeds build_hash, so values derived from the hash are
# placeholders substituted afterwards.
locals {
  build_id_placeholder   = "@@BUILD_ID@@"
  serve_path_placeholder = "@@SERVE_PATH@@"
  image_file_placeholder = "${var.cluster_name}-${local.build_id_placeholder}.raw"

  factory_script = replace(
    replace(
      replace(module.image_factory.script_stripped, local.image_file_placeholder, local.image_file),
      local.serve_path_placeholder, random_id.serve_path.hex
    ),
    local.build_id_placeholder, module.config.build_id
  )
}
