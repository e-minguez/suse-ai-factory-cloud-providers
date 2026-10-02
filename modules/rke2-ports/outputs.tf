output "control_plane" {
  description = "Ports open on control-plane nodes: API, etcd, node ports and ingress."
  value       = merge(local.api, local.etcd, local.node, local.ingress)
}

output "control_plane_ingress" {
  description = "Ingress subset of control_plane, the ports the ingress load balancer reaches."
  value       = local.ingress
}

output "worker" {
  description = "Ports open on worker nodes, GPU or not: no API, supervisor, etcd or ingress. Agents only dial out to the API."
  value       = local.node
}

output "lb_api" {
  description = "Ports the API load balancer listens on and forwards."
  value       = local.api
}

output "lb_ingress" {
  description = "Ports the ingress load balancer listens on; empty when there is no ingress controller."
  value       = { for k, v in local.ingress : k => v if k != "ingress_ping" }
}

output "lb_ingress_health" {
  description = "Health check per ingress LB listener (http, https): type tcp or http, target port and path. Empty without an ingress controller."
  value = var.ingress_controller == "traefik" ? {
    for k in ["http", "https"] : k => { type = "http", port = 8080, path = "/ping" }
    } : var.ingress_controller == "ingress-nginx" ? {
    http  = { type = "tcp", port = 80, path = null }
    https = { type = "tcp", port = 443, path = null }
  } : {}
}
