# Output set shared by every provider module (docs/conventions.md#outputs).
# Provider-only data goes in provider_details.

locals {
  jumphost_access = {
    public_ip  = exoscale_compute_instance.jumphost.public_ip_address
    private_ip = local.jumphost_private_ip
    ssh_user   = var.jumphost_username != "" ? var.jumphost_username : "root"
  }

  build_status_value = {
    method     = "http"
    url_or_key = local.image_url
    hosts      = [local.jumphost_private_ip]
  }

  # Members as the API lists them, oldest first. The pool has one Ignition
  # entry; init marks the oldest member, the one scripts/kubeconfig.sh and
  # tools/multicluster talk to (the bootstrap member while it exists).
  cp_nodes = {
    for i, m in local.cp_members : m.name => {
      role          = "control_plane"
      pool          = "cp"
      init          = i == 0
      zone          = local.zone
      ssh_user      = var.node_username
      private_ip    = m.private_ip
      public_ip     = m.public_ip
      instance_type = local.control_plane_type
      id            = m.id
    }
  }

  agent_map = {
    for n in local.agent_nodes : n.hostname => {
      role          = n.role
      pool          = n.pool
      init          = false
      zone          = local.zone
      ssh_user      = var.node_username
      private_ip    = local.agent_private_ip[n.hostname]
      public_ip     = exoscale_compute_instance.agent[n.hostname].public_ip_address
      instance_type = n.instance_type
      id            = exoscale_compute_instance.agent[n.hostname].id
    } if contains(keys(exoscale_compute_instance.agent), n.hostname)
  }
}

output "provider" {
  description = "Provider name, for tools that dispatch on it."
  value       = "exoscale"
}

output "cluster_name" {
  description = "Cluster name."
  value       = var.cluster_name
}

output "region" {
  description = "Exoscale zone the cluster runs in."
  value       = local.zone
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
  description = "IPv4 of the network load balancer."
  value       = local.api_vip
}

output "ingress_endpoint" {
  description = "URL of the ingress listeners on the network load balancer. null when ingress_controller is none."
  value       = var.ingress_controller == "none" ? null : "https://${local.api_vip}"
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
  description = "Cluster nodes keyed by hostname; control planes are the pool's current members. Empty when deploy_nodes is false."
  value       = tomap(merge(local.cp_nodes, local.agent_map))
}

output "image" {
  description = "Image build ID and the template ID per zone; none while the template does not exist."
  value = {
    build_id = module.config.build_id
    rebuild  = var.image_rebuild
    ids      = { for z in [local.zone] : z => local.effective_template_id if local.effective_template_id != null }
  }
}

output "egress_ips" {
  description = "Public source IPs of cluster egress: every node egresses from its own public IP."
  value = sort(concat(
    [for m in local.cp_members : m.public_ip if m.public_ip != null],
    [for h, a in exoscale_compute_instance.agent : a.public_ip_address],
  ))
}

output "network" {
  description = "Private network CIDR, also the only subnet."
  value = {
    vpc_cidr     = local.vpc_cidr
    subnet_cidrs = [local.vpc_cidr]
  }
}

output "build_status" {
  description = "Image import URL and the build hosts reachable via the jumphost while no template exists yet; null once it does."
  value       = local.effective_template_id == null ? local.build_status_value : null
}

output "next_steps" {
  description = "Post-deploy hints."
  value = join("\n", concat(
    ["Kubernetes API : https://${local.api_host}:6443"],
    contains(module.config.enabled_components, "rancher") ? [
      "Rancher        : https://${local.rancher_hostname}",
      "                 password: terraform -chdir=${local.cluster_dir} output -raw rancher_bootstrap_password",
    ] : [],
    local.effective_template_id == null ? [
      "Image build    : in progress; follow it with ${local.helper["build-logs"]}",
      ] : !var.deploy_nodes ? [
      "Nodes          : not deployed (deploy_nodes = false); set it to true and apply again",
      "Build logs     : ${local.helper["build-logs"]}",
      ] : !var.cp_initialized ? [
      "Control plane  : one member (bootstrap); run deploy.sh to scale it to ${var.control_plane_count}",
      ] : [
      "Kubeconfig     : ${local.helper["kubeconfig"]} -o ~/.kube/${var.cluster_name}.yaml   (admin credential, mode 600)",
      "SSH            : ${local.helper["ssh"]} <node>   nodes: terraform -chdir=${local.cluster_dir} output nodes",
    ],
  ))
}

output "provider_details" {
  description = "Exoscale-specific values: pool, load balancer, network and security group IDs, and the cp_initialized pin deploy.sh keeps."
  value = {
    control_plane_pool_id = one(exoscale_instance_pool.control_plane[*].id)
    nlb_id                = exoscale_nlb.this.id
    private_network_id    = exoscale_private_network.this.id
    security_group_ids = {
      jumphost      = exoscale_security_group.jumphost.id
      control_plane = exoscale_security_group.control_plane.id
      agent         = exoscale_security_group.agent.id
    }
    cp_initialized = var.cp_initialized
  }
}
