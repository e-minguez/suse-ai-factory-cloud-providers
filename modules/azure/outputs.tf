# Output set shared by every provider module (docs/conventions.md#outputs).
# Provider-only data goes in provider_details.

output "provider" {
  description = "Provider name, for tools that dispatch on it."
  value       = "azure"
}

output "cluster_name" {
  description = "Cluster name."
  value       = var.cluster_name
}

output "region" {
  description = "Azure location the cluster runs in."
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
  description = "Static public IPv4 of the load balancer."
  value       = local.api_vip
}

output "ingress_endpoint" {
  description = "URL of the ingress rules on the load balancer. null when ingress_controller is none."
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
  description = "Jumphost addresses and login user. The addresses are null when image_id is set and deploy_nodes is false: no jumphost exists then."
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
      private_ip    = azurerm_network_interface.node[h].private_ip_address
      public_ip     = null
      instance_type = n.instance_type
      id            = azurerm_linux_virtual_machine.node[h].id
      ssh_user      = var.node_username
    }
  }
}

output "image" {
  description = "Image build ID and the gallery image version ID per region; none while the image does not exist."
  value = {
    build_id = module.config.build_id
    rebuild  = var.image_rebuild
    ids      = { for r in [local.region] : r => local.effective_image_id if local.effective_image_id != null }
  }
}

output "egress_ips" {
  description = "Public source IPs of cluster egress: the NAT gateway address of the private subnet."
  value       = local.egress_ips
}

output "network" {
  description = "Virtual network CIDR and the public and private subnet CIDRs."
  value = {
    vpc_cidr     = local.vpc_cidr
    subnet_cidrs = [local.public_subnet_cidr, local.private_subnet_cidr]
  }
}

output "build_status" {
  description = "Storage location of the VHD and the build host reachable via the jumphost while no image exists yet; null once it does."
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
  description = "Azure-specific values: subscription, resource group, virtual network, subnets, network security groups, load balancer, gallery image, jumphost and NAT gateway IDs, and the build storage account."
  value = {
    subscription_id            = var.azure_subscription_id
    resource_group             = local.resource_group_name
    resource_group_id          = local.resource_group_id
    virtual_network_id         = local.virtual_network_id
    subnet_ids                 = { public = local.public_subnet_id, private = local.private_subnet_id }
    network_security_group_ids = { for n, g in azurerm_network_security_group.this : n => g.id }
    load_balancer_id           = azurerm_lb.this.id
    public_ip_id               = azurerm_public_ip.lb.id
    zones                      = local.zones
    image_id                   = local.effective_image_id
    jumphost_id                = one(azurerm_linux_virtual_machine.jumphost[*].id)
    nat_gateway_id             = local.nat_gateway_id
    storage_account            = local.build_image ? local.storage_account_name : null
    gallery                    = one(azurerm_shared_image_gallery.this[*].name)
  }
}
