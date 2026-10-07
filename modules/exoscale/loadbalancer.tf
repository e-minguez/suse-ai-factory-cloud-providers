# One NLB for the API (6443, 9345) and ingress (80, 443). Created before the
# jumphost: its address is in the image (apiVIP, api_host, Rancher hostname).
# It returns traffic straight from the members' public interface with the
# client address, so the control plane security group admits the clients.
resource "exoscale_nlb" "this" {
  zone        = local.zone
  name        = "${var.cluster_name}-lb"
  description = "RKE2 API, supervisor and ingress"
  labels      = merge(local.labels, { "elemental-role" = "lb" })
}

# TCP checks: 6443 and 9345 speak TLS.
resource "exoscale_nlb_service" "api" {
  for_each = var.deploy_nodes ? module.rke2_ports.lb_api : {}

  zone             = local.zone
  nlb_id           = exoscale_nlb.this.id
  name             = replace(each.key, "_", "-")
  instance_pool_id = one(exoscale_instance_pool.control_plane[*].id)
  protocol         = "tcp"
  port             = each.value.from
  target_port      = each.value.from
  strategy         = "round-robin"

  healthcheck {
    mode     = "tcp"
    port     = each.value.from
    interval = 10
    timeout  = 5
    retries  = 2
  }
}

# Ingress listeners with the check rke2-ports defines per ingress controller
# (Traefik: http /ping on 8080).
resource "exoscale_nlb_service" "ingress" {
  for_each = var.deploy_nodes ? module.rke2_ports.lb_ingress : {}

  zone             = local.zone
  nlb_id           = exoscale_nlb.this.id
  name             = "ingress-${each.key}"
  instance_pool_id = one(exoscale_instance_pool.control_plane[*].id)
  protocol         = "tcp"
  port             = each.value.from
  target_port      = each.value.from
  strategy         = "source-hash"

  healthcheck {
    mode     = module.rke2_ports.lb_ingress_health[each.key].type
    port     = module.rke2_ports.lb_ingress_health[each.key].port
    uri      = module.rke2_ports.lb_ingress_health[each.key].path
    interval = 10
    timeout  = 5
    retries  = 2
  }
}
