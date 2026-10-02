# The common output set (docs/conventions.md#outputs); evroc-only data is in provider_details.

locals {
  rancher_enabled = contains(module.config.enabled_components, "rancher")

  # Node maps keyed by hostname. A provider "" public address means none.
  control_plane_node_info = {
    for vm in evroc_virtual_machine.control_plane : vm.name => {
      role          = "control_plane"
      pool          = "cp"
      init          = local.control_plane_nodes_map[vm.name].init
      zone          = vm.zone
      private_ip    = vm.private_ipv4_address
      public_ip     = vm.public_ipv4_address == null || vm.public_ipv4_address == "" ? tostring(null) : vm.public_ipv4_address
      instance_type = vm.flavor
      id            = vm.fqid
      ssh_user      = var.node_username
    }
  }

  agent_node_info = {
    for vm in evroc_virtual_machine.agent : vm.name => {
      role          = local.agent_nodes_map[vm.name].role
      pool          = local.agent_nodes_map[vm.name].pool
      init          = false
      zone          = vm.zone
      private_ip    = vm.private_ipv4_address
      public_ip     = vm.public_ipv4_address == null || vm.public_ipv4_address == "" ? tostring(null) : vm.public_ipv4_address
      instance_type = vm.flavor
      id            = vm.fqid
      ssh_user      = var.node_username
    }
  }

  node_info = merge(local.control_plane_node_info, local.agent_node_info)

  jumphost_ssh_user = var.jumphost_username != "" ? var.jumphost_username : "root"

  jumphost_access = {
    public_ip  = try(evroc_public_ip.jumphost.ip_address, null)
    private_ip = try(evroc_virtual_machine.jumphost.private_ipv4_address, null)
    ssh_user   = local.jumphost_ssh_user
  }

  # No build runs once a snapshot is expected: image_ready, or image_ids adopted.
  build_status = local.snapshot_expected ? null : local.build_status_value

  build_status_value = {
    method     = "relay"
    url_or_key = "http://${evroc_public_ip.jumphost.ip_address}:${local.status_relay_port}/zones"
    # Private IPs, reached through the jumphost: the jumphost first, then one builder per zone.
    hosts = concat(
      [evroc_virtual_machine.jumphost.private_ipv4_address],
      [for z in sort(keys(evroc_virtual_machine.builder)) : evroc_virtual_machine.builder[z].private_ipv4_address],
    )
  }

  next_steps = join("\n", concat(
    ["Kubernetes API : https://${local.api_host}:6443"],
    local.rancher_enabled ? [
      "Rancher        : https://${local.rancher_hostname}",
      "                 password: terraform -chdir=${local.cluster_dir} output -raw rancher_bootstrap_password",
    ] : [],
    !local.snapshot_expected ? [
      "Image build    : in progress; follow it with ${local.helper["build-logs"]}",
      ] : !var.deploy_nodes ? [
      "Nodes          : not deployed (deploy_nodes = false); set it to true and apply again",
      "Build logs     : ${local.helper["build-logs"]}",
      ] : [
      "Kubeconfig     : ${local.helper["kubeconfig"]} -o ~/.kube/${var.cluster_name}.yaml   (admin credential, mode 600)",
      "SSH            : ${local.helper["ssh"]} <node>   nodes: terraform -chdir=${local.cluster_dir} output nodes",
    ],
  ))
}

output "provider" {
  description = "Provider name, for tools that dispatch on it."
  value       = "evroc"
}

output "cluster_name" {
  description = "Cluster name, the prefix of every node hostname."
  value       = var.cluster_name
}

output "region" {
  description = "evroc region the cluster runs in."
  value       = var.region
}

output "kubernetes_api_endpoint" {
  description = "Kubernetes API URL on api_host, served by the load balancer at api_vip."
  value       = "https://${local.api_host}:6443"
}

output "api_host" {
  description = "DNS name of the Kubernetes API, present in the API server certificate SANs."
  value       = local.api_host
}

output "api_vip" {
  description = "Public IP of the load balancer that fronts the Kubernetes API."
  value       = local.api_vip
}

output "ingress_endpoint" {
  description = "https:// URL of the ingress address (the same load balancer IP as the API). Null when ingress_controller is \"none\"."
  value       = var.ingress_controller == "none" ? null : "https://${local.api_vip}"
}

output "rancher_url" {
  description = "Rancher UI URL. Null when Rancher is not enabled."
  value       = local.rancher_enabled ? "https://${local.rancher_hostname}" : null
}

output "rancher_hostname" {
  description = "Hostname Rancher's ingress serves. Null when Rancher is not enabled."
  value       = local.rancher_enabled ? local.rancher_hostname : null
}

output "rancher_bootstrap_password" {
  description = "Initial Rancher admin password. Null when Rancher is not enabled."
  value       = local.rancher_enabled ? module.config.rancher_bootstrap_password : null
  sensitive   = true
}

output "jumphost" {
  description = "Jumphost addresses and SSH user; the only inbound admin path. Addresses are null until it exists."
  value       = local.jumphost_access
}

output "nodes" {
  description = "Cluster nodes keyed by hostname: role, pool, init, zone, private_ip, public_ip, instance_type, id, ssh_user. Empty until nodes are deployed."
  value       = local.node_info
}

output "image" {
  description = "Image build id and the snapshot id per zone (null before the build completes)."
  value = {
    build_id = local.build_id
    rebuild  = var.image_rebuild
    ids      = local.effective_snapshot_ids
  }
}

output "egress_ips" {
  description = "Public source IPs of nodes that have one. Nodes without a public IP use platform egress addresses that are not exposed."
  value       = sort(compact([for n in local.node_info : n.public_ip]))
}

output "network" {
  description = "VPC CIDR and the per-zone subnet CIDRs."
  value = {
    vpc_cidr     = local.vpc_cidr
    subnet_cidrs = local.subnet_cidrs
  }
}

output "build_status" {
  description = "Build-status relay URL and the build hosts (private IPs reachable via the jumphost) while an image build runs; null afterwards."
  value       = local.build_status
}

output "next_steps" {
  description = "Post-deploy hints; contains no secrets."
  value       = local.next_steps
}

output "provider_details" {
  description = "evroc-specific data: quota and GPU demand, security groups, image target disks, control-plane FQIDs, builder addresses."
  value = {
    # Limits only: org-wide usage changes with other workloads and would dirty every plan.
    quota_request = {
      demand = local.quota_demand
      limit = {
        vcpus      = data.evroc_organization_quota.this.compute_vcpus
        memory     = data.evroc_organization_quota.this.compute_memory
        public_ips = data.evroc_organization_quota.this.networking_public_ips
      }
    }
    gpu_quota_request = {
      by_pool  = local.gpu_pool_demand
      by_model = local.gpu_demand_by_model
    }
    security_group_names = concat(
      [evroc_security_group.jumphost.name, evroc_security_group.control_plane.name],
      evroc_security_group.builder[*].name,
      evroc_security_group.agent[*].name,
    )
    image_target_disk_names = local.image_target_disk_names
    control_plane_fqids     = local.control_plane_fqids
    builder_private_ips     = { for z, vm in evroc_virtual_machine.builder : z => vm.private_ipv4_address }
  }
}
