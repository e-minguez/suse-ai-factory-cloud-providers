# Output set shared by every provider module (docs/conventions.md#outputs).
# Provider-only data goes in provider_details.

output "provider" {
  description = "Provider name, for tools that dispatch on it."
  value       = "harvester"
}

output "cluster_name" {
  description = "Cluster name."
  value       = var.cluster_name
}

output "region" {
  description = "Free-form region label (Harvester has no regions)."
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
  description = "Static IPv4 of the Kubernetes API, held by MetalLB."
  value       = var.api_vip
}

output "ingress_endpoint" {
  description = "URL of the ingress controller on ingress_vip. null when ingress_controller is none."
  value       = var.ingress_controller == "none" ? null : "https://${var.ingress_vip}"
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
  description = "The build host (common output name jumphost): login user (root when jumphost_username is empty) and VLAN address (public_ip and private_ip are the same). The addresses are null with buildhost_power_off and when image_id is set (no build host): scripts/ssh.sh then connects to the nodes directly."
  value       = local.jumphost_output
}

output "nodes" {
  description = "Cluster nodes keyed by hostname. Empty when deploy_nodes is false. private_ip is the DHCP address reported by the guest agent; provider_details.macs lists the fixed MACs for DHCP reservations."
  value = {
    for h, n in local.nodes : h => {
      role          = n.role
      pool          = n.pool
      init          = n.init
      zone          = null
      private_ip    = try(coalesce(harvester_virtualmachine.node[h].network_interface[0].ip_address), null)
      public_ip     = null
      instance_type = n.instance_type
      id            = harvester_virtualmachine.node[h].id
      ssh_user      = var.node_username
    }
  }
}

output "image" {
  description = "Image build ID and the image (<namespace>/<name>) under the region label; none while the image does not exist."
  value = {
    build_id = module.config.build_id
    rebuild  = var.image_rebuild
    ids      = { for r in [local.region] : r => local.effective_image_id if local.effective_image_id != null }
  }
}

output "egress_ips" {
  description = "Public source IPs of cluster egress. Always empty: egress leaves through the gateway of the VM network, which Terraform cannot read."
  value       = []
}

output "network" {
  description = "Subnet of the VM network; subnet_cidrs holds the same CIDR."
  value = {
    vpc_cidr     = local.vpc_cidr
    subnet_cidrs = [local.vpc_cidr]
  }
}

output "build_status" {
  description = "URL of the build status file and the build host while no image exists yet; null once it does."
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
    ["Kubernetes API : https://${local.api_host}:6443   (VIP ${var.api_vip}, answers once the first control plane is up)"],
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
  description = "Harvester-specific values: namespace, VM network, StorageClass, node and buildhost image, VIPs and the MAC address of every VM."
  value = {
    namespace       = var.harvester_namespace
    network         = var.vpc_id
    storage_class   = var.storage_class_name
    node_image      = local.effective_image_id
    node_images     = local.node_images
    buildhost_image = local.buildhost_enabled ? local.buildhost_image_ref : null
    api_vip         = var.api_vip
    ingress_vip     = var.ingress_vip
    macs            = { for h, n in local.nodes : h => local.macs[h] }
  }
}
