# Output set shared by every provider module (docs/conventions.md#outputs).
# Provider-only data goes in provider_details.

locals {
  jumphost_access = {
    public_ip  = vultr_instance.jumphost.main_ip
    private_ip = vultr_instance.jumphost.internal_ip
    ssh_user   = var.jumphost_username != "" ? var.jumphost_username : "root"
  }

  build_status_value = {
    method     = "http"
    url_or_key = local.image_url
    hosts      = [vultr_instance.jumphost.internal_ip]
  }

  # A vpc_only instance has no public IP, whatever main_ip reports ("0.0.0.0"
  # or its VPC address); the flag decides.
  cp_nodes = {
    for i, s in vultr_instance.control_plane : local.control_plane_nodes[i].hostname => {
      role          = "control_plane"
      pool          = local.control_plane_nodes[i].pool
      init          = local.control_plane_nodes[i].init
      zone          = null
      ssh_user      = var.node_username
      private_ip    = s.internal_ip
      public_ip     = null
      instance_type = local.control_plane_plan
      id            = s.id
    }
  }

  agent_bare_metal_map = {
    for n in local.agent_bare_metal_nodes : n.hostname => {
      role          = n.role
      pool          = n.pool
      init          = false
      zone          = null
      ssh_user      = var.node_username
      private_ip    = null # vultr_bare_metal_server exposes no VPC address.
      public_ip     = vultr_bare_metal_server.agent[n.hostname].main_ip
      instance_type = n.plan
      id            = vultr_bare_metal_server.agent[n.hostname].id
    } if contains(keys(vultr_bare_metal_server.agent), n.hostname)
  }

  agent_cloud_map = {
    for n in local.agent_cloud_nodes : n.hostname => {
      role          = n.role
      pool          = n.pool
      init          = false
      zone          = null
      ssh_user      = var.node_username
      private_ip    = vultr_instance.agent_cloud[n.hostname].internal_ip
      public_ip     = n.vpc_only ? null : vultr_instance.agent_cloud[n.hostname].main_ip
      instance_type = n.plan
      id            = vultr_instance.agent_cloud[n.hostname].id
    } if contains(keys(vultr_instance.agent_cloud), n.hostname)
  }

  # Public agent node IPs (GPU and worker), bare metal first. vpc_only cloud
  # nodes are dropped by their flag: their main_ip has read "0.0.0.0" and also
  # the VPC address, and the latter in the LB's 9345 firewall blocked every
  # connection. The address filter stays as a backstop.
  agent_public_ipv4 = [
    for ip in concat(
      [for k in sort(keys(vultr_bare_metal_server.agent)) : vultr_bare_metal_server.agent[k].main_ip],
      [for k in sort(keys(vultr_instance.agent_cloud)) : vultr_instance.agent_cloud[k].main_ip if vultr_instance.agent_cloud[k].vpc_only != true],
    ) : ip if ip != "" && ip != "0.0.0.0"
  ]

  vpc_subnet_cidr = "${vultr_vpc.this.v4_subnet}/${vultr_vpc.this.v4_subnet_mask}"
}

output "provider" {
  description = "Provider name, for tools that dispatch on it."
  value       = "vultr"
}

output "cluster_name" {
  description = "Cluster name."
  value       = var.cluster_name
}

output "region" {
  description = "Vultr region the cluster runs in."
  value       = var.region
}

output "kubernetes_api_endpoint" {
  description = "Kubernetes API URL on api_host, port 6443."
  value       = "https://${local.api_host}:6443"
}

output "api_host" {
  description = "DNS name of the Kubernetes API; it is in the API server certificate SANs."
  value       = local.api_host
}

output "api_vip" {
  description = "IPv4 of the API load balancer."
  value       = local.api_vip
}

output "ingress_endpoint" {
  description = "URL of the ingress load balancer. null unless ingress_controller is traefik."
  value       = local.ingress_lb_ipv4 == null ? null : "https://${local.ingress_lb_ipv4}"
}

output "rancher_url" {
  description = "Rancher UI URL. null when rancher is not in components."
  value       = contains(module.config.enabled_components, "rancher") ? "https://${local.rancher_hostname}" : null
}

output "rancher_hostname" {
  description = "Hostname Rancher's ingress is configured for. null when rancher is not in components."
  value       = contains(module.config.enabled_components, "rancher") ? local.rancher_hostname : null
}

output "rancher_bootstrap_password" {
  description = "Rancher initial admin password. null when rancher is not in components."
  value       = contains(module.config.enabled_components, "rancher") ? module.config.rancher_bootstrap_password : null
  sensitive   = true
}

output "jumphost" {
  description = "Jumphost addresses and login user (root when jumphost_username is empty)."
  value       = local.jumphost_access
}

output "nodes" {
  description = "Cluster nodes keyed by hostname. Empty when deploy_nodes is false."
  value       = tomap(merge(local.cp_nodes, local.agent_bare_metal_map, local.agent_cloud_map))
}

output "image" {
  description = "Image build ID and the snapshot ID per region. The snapshot is account-wide: one key, none while it does not exist."
  value = {
    build_id = module.config.build_id
    rebuild  = var.image_rebuild
    ids      = { for r in [var.region] : r => local.effective_snapshot_id if local.effective_snapshot_id != null }
  }
}

output "egress_ips" {
  description = "Public source IPs of cluster egress (NAT gateway)."
  value       = tolist(vultr_nat_gateway.this.public_ips)
}

output "network" {
  description = "VPC CIDR and subnet CIDRs."
  value = {
    vpc_cidr     = local.vpc_subnet_cidr
    subnet_cidrs = [local.vpc_subnet_cidr]
  }
}

output "build_status" {
  description = "Image import URL and the build hosts reachable via the jumphost while no snapshot exists yet; null once it does."
  value       = local.effective_snapshot_id == null ? local.build_status_value : null
}

output "next_steps" {
  description = "Post-deploy hints."
  value = join("\n", concat(
    ["Kubernetes API : https://${local.api_host}:6443"],
    contains(module.config.enabled_components, "rancher") ? [
      "Rancher        : https://${local.rancher_hostname}",
      "                 password: terraform -chdir=${local.cluster_dir} output -raw rancher_bootstrap_password",
    ] : [],
    local.effective_snapshot_id == null ? [
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

output "provider_details" {
  description = "Vultr-specific values. agent_node_cidrs and agent_cloud_firewall_group_id cover GPU and worker agents alike; node_tags lists the tags of each node (build_id makes vultr_instance tags unknown at plan)."
  value = {
    control_plane_ids             = vultr_instance.control_plane[*].id
    agent_node_cidrs              = [for ip in local.agent_public_ipv4 : "${ip}/32"]
    nat_gateway_public_cidrs      = [for ip in vultr_nat_gateway.this.public_ips : "${ip}/32"]
    nat_gateway_private_ip        = vultr_nat_gateway.this.private_ips[0]
    agent_cloud_firewall_group_id = one(vultr_firewall_group.agent_cloud[*].id)
    jumphost_vpc_ip               = vultr_instance.jumphost.internal_ip
    node_tags                     = local.node_tags
  }
}
