# Re-exports the module outputs 1:1. Identical in every example (check-consistency).

output "provider" {
  description = "Provider name."
  value       = module.ai_factory.provider
}

output "cluster_name" {
  description = "Cluster name."
  value       = module.ai_factory.cluster_name
}

output "region" {
  description = "Region the cluster runs in."
  value       = module.ai_factory.region
}

output "kubernetes_api_endpoint" {
  description = "Kubernetes API URL."
  value       = module.ai_factory.kubernetes_api_endpoint
}

output "api_host" {
  description = "DNS name of the Kubernetes API."
  value       = module.ai_factory.api_host
}

output "api_vip" {
  description = "IPv4 of the API load balancer."
  value       = module.ai_factory.api_vip
}

output "ingress_endpoint" {
  description = "URL of the ingress load balancer, or null."
  value       = module.ai_factory.ingress_endpoint
}

output "rancher_url" {
  description = "Rancher UI URL, or null."
  value       = module.ai_factory.rancher_url
}

output "rancher_hostname" {
  description = "Rancher hostname, or null."
  value       = module.ai_factory.rancher_hostname
}

output "rancher_bootstrap_password" {
  description = "Rancher initial admin password."
  value       = module.ai_factory.rancher_bootstrap_password
  sensitive   = true
}

output "jumphost" {
  description = "Jumphost public IP, private IP and SSH user."
  value       = module.ai_factory.jumphost
}

output "nodes" {
  description = "Cluster nodes keyed by hostname."
  value       = module.ai_factory.nodes
}

output "image" {
  description = "Image build ID and image IDs."
  value       = module.ai_factory.image
}

output "egress_ips" {
  description = "Public source IPs of cluster egress."
  value       = module.ai_factory.egress_ips
}

output "network" {
  description = "VPC CIDR and subnet CIDRs."
  value       = module.ai_factory.network
}

output "build_status" {
  description = "Image build location while building, else null."
  value       = module.ai_factory.build_status
}

output "next_steps" {
  description = "Post-deploy hints."
  value       = module.ai_factory.next_steps
}

output "provider_details" {
  description = "Provider-specific values."
  value       = module.ai_factory.provider_details
}
