output "registrations" {
  description = "Registration manifest URL per downstream directory. Contains the registration token."
  sensitive   = true
  value = {
    for k, c in rancher2_cluster.downstream : k => c.cluster_registration_token[0].manifest_url
  }
}

output "rancher_insecure" {
  description = "Whether cluster.sh should skip TLS verification when it fetches the manifests."
  value       = var.rancher_insecure
}

output "cluster_ids" {
  description = "Rancher cluster ID per downstream directory."
  value       = { for k, c in rancher2_cluster.downstream : k => c.id }
}

output "admin_password" {
  description = "Rancher admin password set by the first login (bootstrap = true); rancher2_bootstrap replaces the bootstrap password with a random one. Null without bootstrap."
  sensitive   = true
  value       = var.bootstrap ? rancher2_bootstrap.admin[0].current_password : null
}
