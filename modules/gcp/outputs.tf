# Output set shared by every provider module (docs/conventions.md#outputs).
# Provider-only data goes in provider_details.

output "provider" {
  description = "Provider name, for tools that dispatch on it."
  value       = "gcp"
}

output "cluster_name" {
  description = "Cluster name."
  value       = var.cluster_name
}

output "region" {
  description = "Google Cloud region the cluster runs in."
  value       = local.region
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
  description = "Reserved internal IPv4 of the internal passthrough load balancer: the address nodes join through."
  value       = local.api_vip
}

output "ingress_endpoint" {
  description = "URL of the ingress listeners on the external load balancer. null when ingress_controller is none."
  value       = var.ingress_controller == "none" ? null : "https://${local.external_address}"
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
  description = "Jumphost addresses and login user (root when jumphost_username is empty). The addresses are null when image_id is set and deploy_nodes is false: no jumphost exists then."
  value       = local.jumphost_access
}

output "nodes" {
  description = "Cluster nodes keyed by hostname. Empty when deploy_nodes is false."
  value = {
    for h, n in local.nodes : h => {
      role          = n.role
      pool          = n.pool
      init          = n.init
      zone          = n.zone
      private_ip    = google_compute_instance.node[h].network_interface[0].network_ip
      public_ip     = try(google_compute_instance.node[h].network_interface[0].access_config[0].nat_ip, null)
      instance_type = n.instance_type
      id            = google_compute_instance.node[h].id
      ssh_user      = var.node_username
    }
  }
}

output "image" {
  description = "Image build ID and the image self link per region (images are global); none while the image does not exist."
  value = {
    build_id = module.config.build_id
    rebuild  = var.image_rebuild
    ids      = { for r in [local.region] : r => local.effective_image_id if local.effective_image_id != null }
  }
}

output "egress_ips" {
  description = "Public source IPs of cluster egress: the reserved Cloud NAT address."
  value       = [google_compute_address.nat.address]
}

output "network" {
  description = "VPC CIDR and the subnet CIDR (one regional subnet)."
  value = {
    vpc_cidr     = local.vpc_cidr
    subnet_cidrs = [local.vpc_cidr]
  }
}

output "build_status" {
  description = "Guest attributes of the build host (project, zone, instance) and the build host reachable via the jumphost while no image exists yet; null once it does."
  value       = local.effective_image_id == null ? local.build_status_value : null
}

output "security" {
  description = "SUSE Security (NeuVector): role, Manager URL and CA (management only) and federation endpoint. Null when neither security component is enabled."
  value       = module.config.security
}

output "security_credentials" {
  description = "SUSE Security admin password and federation join token. Null when neither security component is enabled."
  value       = module.config.security_credentials
  sensitive   = true
}

output "observability" {
  description = "SUSE Observability URL, CA certificate and OTLP endpoints. Null when observability-server is not enabled."
  value       = module.config.observability
}

output "observability_credentials" {
  description = "SUSE Observability admin password and bootstrap token. Null when observability-server is not enabled."
  value       = module.config.observability_credentials
  sensitive   = true
}

output "next_steps" {
  description = "Post-deploy hints."
  value = join("\n", concat(
    ["Kubernetes API : https://${local.api_host}:6443"],
    contains(module.config.enabled_components, "rancher") ? [
      "Rancher        : https://${local.rancher_hostname}",
      "                 password: terraform -chdir=${local.cluster_dir} output -raw rancher_bootstrap_password  (until cluster.sh register --bootstrap replaces it)",
    ] : [],
    local.effective_image_id == null ? [
      "Image build    : in progress; follow it with ${local.helper["build-logs"]}",
      ] : !var.deploy_nodes ? [
      "Nodes          : not deployed (deploy_nodes = false); set it to true and apply again",
      "Image          : ${local.effective_image_id}",
      "Build logs     : ${local.helper["build-logs"]}",
      ] : [
      "Kubeconfig     : ${local.helper["kubeconfig"]} --wait -o ~/.kube/${var.cluster_name}.yaml   (admin credential, mode 600; --wait retries until the node serves it)",
      "SSH            : ${local.helper["ssh"]} <node>   nodes: terraform -chdir=${local.cluster_dir} output nodes",
    ],
  ))
}

output "provider_details" {
  description = "GCP-specific values: project, network, subnet, load balancer addresses and forwarding rules, NAT address, image, jumphost and instance group names."
  value = {
    project    = var.gcp_project
    network    = google_compute_network.this.self_link
    subnetwork = google_compute_subnetwork.this.self_link
    load_balancers = {
      external_address = local.external_address
      internal_address = local.api_vip
      forwarding_rules = { for k, r in google_compute_forwarding_rule.this : k => r.id }
      backend_services = { for k, b in google_compute_region_backend_service.this : k => b.id }
    }
    instance_groups = { for z, g in google_compute_instance_group.control_plane : z => g.self_link }
    nat_address     = google_compute_address.nat.address
    router          = google_compute_router.this.self_link
    image           = local.effective_image_id
    jumphost        = one(google_compute_instance.jumphost[*].self_link)
    zones           = local.zones
  }
}
