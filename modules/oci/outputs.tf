# Output set shared by every provider module (docs/conventions.md#outputs).
# Provider-only data goes in provider_details.

output "provider" {
  description = "Provider name, for tools that dispatch on it."
  value       = "oci"
}

output "cluster_name" {
  description = "Cluster name."
  value       = var.cluster_name
}

output "region" {
  description = "OCI region the cluster runs in."
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
  description = "Reserved public IPv4 of the network load balancer."
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
      private_ip    = oci_core_instance.node[h].private_ip
      public_ip     = null
      instance_type = n.instance_type
      id            = oci_core_instance.node[h].id
      ssh_user      = var.node_username
    }
  }
}

output "image" {
  description = "Image build ID and the image OCID per region; none while the image does not exist."
  value = {
    build_id = module.config.build_id
    rebuild  = var.image_rebuild
    ids      = { for r in [local.region] : r => local.effective_image_id if local.effective_image_id != null }
  }
}

output "egress_ips" {
  description = "Public source IPs of cluster egress: the NAT gateway address of the private subnet."
  value       = [local.nat_ip]
}

output "network" {
  description = "VCN CIDR and the public and private subnet CIDRs."
  value = {
    vpc_cidr     = local.vpc_cidr
    subnet_cidrs = [local.public_subnet_cidr, local.private_subnet_cidr]
  }
}

output "build_status" {
  description = "Object Storage location of the qcow2 and the build host reachable via the jumphost while no image exists yet; null once it does."
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
  description = "OCI-specific values: compartment, VCN, subnet, network security group, load balancer, reserved IP, image, jumphost and NAT gateway OCIDs, fault domains and the build bucket."
  value = {
    compartment_id = var.oci_compartment_ocid
    vcn_id         = local.vcn_id
    subnet_ids = {
      public  = local.public_subnet_id
      private = local.private_subnet_id
    }
    network_security_group_ids = local.nsg_ids
    nlb_id                     = oci_network_load_balancer_network_load_balancer.this.id
    reserved_public_ip_id      = oci_core_public_ip.nlb.id
    availability_domains       = { for z in local.zones : z => lookup(local.ad_names, z, null) }
    image_id                   = local.effective_image_id
    jumphost_id                = one(oci_core_instance.jumphost[*].id)
    nat_gateway_id             = local.nat_gateway_id
    fault_domains              = { for h, n in local.nodes : h => n.fault_domain }
    build_bucket               = local.bucket_name
    namespace                  = data.oci_objectstorage_namespace.this.namespace
  }
}
