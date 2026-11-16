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

  # An OCI region identifier (eu-frankfurt-1 offers VM.GPU.A10.1 and VM.GPU.A10.2).
  region = coalesce(var.region, "eu-frankfurt-1")

  vpc_cidr_new = coalesce(var.vpc_cidr, "10.20.0.0/20")
  # An existing VCN (vpc_id) without vpc_cidr uses its first CIDR block.
  vpc_cidr = local.create_network || var.vpc_cidr != null ? local.vpc_cidr_new : try(data.oci_core_vcn.existing[0].cidr_blocks[0], local.vpc_cidr_new)
  # VCN traffic uses 9000-byte frames; traffic to the internet is limited to 1500 by the platform.
  vpc_mtu      = coalesce(var.vpc_mtu, 9000)
  pod_veth_mtu = local.vpc_mtu - 50
  vpc_prefix   = tonumber(split("/", local.vpc_cidr)[1])

  # Created VCN: low half public subnet (jumphost, NLB), high half private subnet (nodes).
  public_subnet_cidr  = local.create_network ? cidrsubnet(local.vpc_cidr, 1, 0) : try(data.oci_core_subnet.public[0].cidr_block, null)
  private_subnet_cidr = local.create_network ? cidrsubnet(local.vpc_cidr, 1, 1) : try(data.oci_core_subnet.private[0].cidr_block, null)

  control_plane_type    = coalesce(var.control_plane_instance_type, "VM.Standard.E5.Flex:4x32")
  control_plane_disk_gb = coalesce(var.control_plane_disk_size_gb, 100)
  agent_disk_gb         = 200
  jumphost_type         = coalesce(var.jumphost_instance_type, "VM.Standard.E5.Flex:2x16")
  jumphost_disk_gb      = coalesce(var.jumphost_disk_size_gb, 100)

  managed_labels = {
    "elemental-cluster"    = var.cluster_name
    "elemental-managed-by" = "terraform"
    "elemental-module"     = "ai-factory"
    "elemental-created"    = formatdate("YYYYMMDD-hhmmss", time_static.created.rfc3339)
  }
  # var.tags cannot use the managed prefix, so it never overrides these keys.
  labels = merge(local.managed_labels, var.tags)

  api_vip_mode = "external"
  # Import runs inside OCI after the upload; both waits are upper bounds.
  image_build_timeout = 5400
  # A pre-authenticated request must outlive build, upload and import.
  par_expiry_hours = 24
  # Where cloud-init unpacks the Elemental config on the jumphost.
  config_dir = "/opt/elemental-config"
}

# Availability domains: zones are the lowercase short names ("ad-1"); OCI names
# carry a tenancy prefix ("KiWy:EU-FRANKFURT-1-AD-1").
data "oci_identity_availability_domains" "this" {
  compartment_id = var.oci_tenancy_ocid
}

locals {
  ad_names = {
    for ad in data.oci_identity_availability_domains.this.availability_domains :
    lower(regex("AD-[0-9]+$", upper(ad.name))) => ad.name
  }
  zones    = length(var.zones) > 0 ? var.zones : [sort(keys(local.ad_names))[0]]
  zone_set = toset(local.zones)
}

locals {
  api_vip = oci_core_public_ip.nlb.ip_address

  # Rancher answers on the NLB's ingress listeners; without an ingress controller
  # the chart still needs a hostname, so the same address is used.
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

# Instance types: "<shape>" for fixed shapes, "<shape>:<ocpus>x<memory_gb>" for
# flex shapes. Parsed here, validated in terraform_data.input_checks.
locals {
  shape_inputs = merge(
    {
      "jumphost"      = local.jumphost_type
      "control plane" = local.control_plane_type
    },
    {
      for k, p in local.agent_pools :
      "${p.role == "gpu" ? "GPU" : "worker"} pool \"${k}\"" => p.instance_type
    },
  )

  shape_format = "^[A-Za-z0-9.]+(:[1-9][0-9]*x[1-9][0-9]*)?$"

  shape_errors = sort(flatten([
    for who, s in local.shape_inputs : (
      !can(regex(local.shape_format, s)) ? ["${who} = \"${s}\" (expected \"<shape>\" or \"<shape>:<ocpus>x<memory_gb>\")"] :
      endswith(lower(split(":", s)[0]), ".flex") && !strcontains(s, ":") ? ["${who} = \"${s}\" (a flex shape needs a size, for example \"${s}:2x16\")"] :
      !endswith(lower(split(":", s)[0]), ".flex") && strcontains(s, ":") ? ["${who} = \"${s}\" (only flex shapes take an <ocpus>x<memory_gb> size)"] :
      []
    )
  ]))

  # Keyed by the instance type string as written.
  shapes = {
    for s in distinct(values(local.shape_inputs)) : s => {
      name   = split(":", s)[0]
      flex   = strcontains(s, ":")
      ocpus  = strcontains(s, ":") ? try(tonumber(regex("^[^:]+:([0-9]+)x[0-9]+$", s)[0]), 0) : null
      memory = strcontains(s, ":") ? try(tonumber(regex("^[^:]+:[0-9]+x([0-9]+)$", s)[0]), 0) : null
    }
  }

  jumphost_shape = local.shapes[local.jumphost_type]
}

# Fault domains per availability domain; nodes of one group are spread across them.
locals {
  fault_domain_count = 3
  zone_count         = length(local.zones)
}

# One image serves every node; role and init ride in per-node Ignition
# user_data. The list ignores deploy_nodes, so the image is the same.
locals {
  # Control planes go round-robin over the zones; within a zone, round-robin
  # over the fault domains.
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
      fault_domain  = "FAULT-DOMAIN-${floor(i / local.zone_count) % local.fault_domain_count + 1}"
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
        zone          = local.agent_pools[pool].zone != null ? local.agent_pools[pool].zone : local.zones[i % local.zone_count]
        fault_domain = "FAULT-DOMAIN-${(
          local.agent_pools[pool].zone != null ? i : floor(i / local.zone_count)
        ) % local.fault_domain_count + 1}"
        disk_size_gb = coalesce(local.agent_pools[pool].disk_size_gb, local.agent_disk_gb)
      }
    ]
  ])

  ignition_nodes = concat(local.control_plane_nodes, local.agent_nodes)
}
