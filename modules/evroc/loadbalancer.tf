# One load balancer for the API, supervisor and ingress ports; health check and
# PROXY protocol are per backend service, so there is one service per port.
# Wiring: listener.route_refs -> l4_route -> backend_service -> backend_pool.

# One pool: control-plane nodes serve the API, supervisor and ingress. Empty on
# the first apply; RKE2 servers retry the 9345 join until a backend answers.
resource "evroc_lb_backend_pool" "control_plane" {
  name         = "${var.cluster_name}-cp-pool"
  backend_refs = local.control_plane_fqids
  project      = var.project
  region       = var.region
  user_labels  = merge(local.common_labels, { "elemental-role" = "lb" })
}

locals {
  # One entry per listener. health_check_target null means the service's own port
  # (resolved in target_port).
  lb_services_all = {
    # The health checker's source is not disclosed: with api_cidrs narrowed it cannot
    # reach 6443, so the check uses the supervisor port, which is open to it.
    kube_api = {
      port                = 6443
      proxy_protocol      = false
      health_check_type   = "tcp"
      health_check_path   = null
      health_check_target = contains(var.api_cidrs, "0.0.0.0/0") ? null : 9345
    }
    supervisor = {
      port                = 9345
      proxy_protocol      = false
      health_check_type   = "tcp"
      health_check_path   = null
      health_check_target = null
    }
    # PROXY protocol only for Traefik (trusted from the VPC CIDR, as in its manifest).
    # Health checks come from rke2-ports: /ping on 8080 for Traefik, TCP for nginx.
    http = {
      port                = 80
      proxy_protocol      = var.ingress_controller == "traefik"
      health_check_type   = try(module.rke2_ports.lb_ingress_health.http.type, "tcp")
      health_check_path   = try(module.rke2_ports.lb_ingress_health.http.path, null)
      health_check_target = try(module.rke2_ports.lb_ingress_health.http.port, null)
    }
    https = {
      port                = 443
      proxy_protocol      = var.ingress_controller == "traefik"
      health_check_type   = try(module.rke2_ports.lb_ingress_health.https.type, "tcp")
      health_check_path   = try(module.rke2_ports.lb_ingress_health.https.path, null)
      health_check_target = try(module.rke2_ports.lb_ingress_health.https.port, null)
    }
  }

  # http/https exist only with an ingress controller.
  lb_services = {
    for k, v in local.lb_services_all : k => v
    if var.ingress_controller != "none" || !contains(["http", "https"], k)
  }
}

# Attributes that restate API defaults are pinned: the provider declares them
# Optional without Computed, so omitting them gives a perpetual diff and update
# races (409 Conflict). Do not remove; see docs/decisions/004-evroc-module-rationale.md.
resource "evroc_lb_backend_service" "cluster" {
  for_each = local.lb_services

  name                  = "${var.cluster_name}-${replace(each.key, "_", "-")}-svc"
  port                  = each.value.port
  backend_pool_ref      = evroc_lb_backend_pool.control_plane.fqid
  proxy_protocol        = each.value.proxy_protocol
  ip_protocol_selection = "IPv4"
  project               = var.project
  region                = var.region

  # `listener` distinguishes the per-port objects.
  user_labels = merge(local.common_labels, {
    "elemental-role"     = "lb"
    "elemental-listener" = each.key
  })

  health_check {
    # Never null: the API stores 0 and the check never passes (docs/decisions/004).
    target_port = coalesce(each.value.health_check_target, each.value.port)

    # API defaults, restated (see above).
    interval            = "5s"
    timeout             = "2s"
    healthy_threshold   = 1
    unhealthy_threshold = 2

    dynamic "tcp" {
      for_each = each.value.health_check_type == "tcp" ? [1] : []
      content {}
    }

    dynamic "http" {
      for_each = each.value.health_check_type == "http" ? [1] : []
      content {
        path = each.value.health_check_path

        # API default, not Computed; the ingress /ping answers 200.
        expected_statuses = [200]
      }
    }
  }
}

resource "evroc_lb_l4_route" "cluster" {
  for_each = local.lb_services

  name                        = "${var.cluster_name}-${replace(each.key, "_", "-")}-route"
  default_backend_service_ref = evroc_lb_backend_service.cluster[each.key].fqid
  project                     = var.project
  region                      = var.region

  user_labels = merge(local.common_labels, {
    "elemental-role"     = "lb"
    "elemental-listener" = each.key
  })
}

locals {
  # One listener per backend service on the same port; derived from lb_services.
  lb_listener_ports = { for k, v in local.lb_services : k => v.port }
}

# backend_network is required: without it the LB attaches to the default VPC and
# resets every connection. Changing it (vpc_cidr, zones) forces replacement and
# the VIP stops answering meanwhile. Needs provider >= 0.9.4.
resource "evroc_loadbalancer" "cluster" {
  name          = "${var.cluster_name}-lb"
  public_ip_ref = evroc_public_ip.cluster.fqid
  project       = var.project
  region        = var.region
  user_labels   = merge(local.common_labels, { "elemental-role" = "lb" })

  # One subnet per zone; a missing zone's backends are unreachable.
  backend_network {
    vpc_ref = evroc_vpc.this.fqid

    dynamic "subnet" {
      for_each = evroc_subnet.this
      content {
        zone       = subnet.key
        subnet_ref = subnet.value.fqid
      }
    }
  }

  dynamic "listener" {
    for_each = local.lb_listener_ports
    content {
      name       = replace(listener.key, "_", "-")
      protocol   = "TCP"
      port       = listener.value
      route_refs = [evroc_lb_l4_route.cluster[listener.key].fqid]
    }
  }
}
