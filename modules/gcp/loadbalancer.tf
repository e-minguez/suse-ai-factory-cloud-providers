# Two regional passthrough network load balancers over the same control planes,
# both created before the image (their addresses are in it):
#   external: 6443 (api_cidrs), 80 and 443 (ingress_cidrs) on a reserved public
#             address; Rancher, api_host and the sslip.io names use it.
#   internal: 6443 and 9345 on a reserved subnet address (api_vip); agents and
#             joining control planes use it.
# Backends are one unmanaged instance group per zone holding that zone's control
# planes. Addresses and forwarding rules carry labels; health checks, backend
# services and instance groups do not (names start with the cluster name).

# Reserved, so the address survives replaced forwarding rules.
resource "google_compute_address" "external_lb" {
  depends_on = [terraform_data.limits_check]

  name         = "${var.cluster_name}-lb-external"
  description  = "External load balancer address of ${var.cluster_name}"
  region       = local.region
  address_type = "EXTERNAL"
  labels       = merge(local.labels, { "elemental-role" = "lb" })
}

# SHARED_LOADBALANCER_VIP: several forwarding rules (one per port) share it.
resource "google_compute_address" "internal_lb" {
  depends_on = [terraform_data.limits_check]

  name         = "${var.cluster_name}-lb-internal"
  description  = "Internal load balancer address (api_vip) of ${var.cluster_name}"
  region       = local.region
  address_type = "INTERNAL"
  purpose      = "SHARED_LOADBALANCER_VIP"
  subnetwork   = local.subnetwork_id
  labels       = merge(local.labels, { "elemental-role" = "lb" })
}

locals {
  # TCP checks for the API ports (TLS); ingress ports use the check rke2-ports defines.
  lb_listeners = merge(
    {
      "ext-kube-api" = {
        scheme = "EXTERNAL", listener = "kube_api", port = module.rke2_ports.lb_api["kube_api"].from
        health = { type = "tcp", port = module.rke2_ports.lb_api["kube_api"].from, path = null }
      }
    },
    {
      for k, v in module.rke2_ports.lb_ingress : "ext-${replace(k, "_", "-")}" => {
        scheme = "EXTERNAL", listener = k, port = v.from, health = module.rke2_ports.lb_ingress_health[k]
      }
    },
    {
      for k, v in module.rke2_ports.lb_api : "int-${replace(k, "_", "-")}" => {
        scheme = "INTERNAL", listener = k, port = v.from, health = { type = "tcp", port = v.from, path = null }
      }
    },
  )

  # Zones that hold control planes: an instance group per zone.
  control_plane_zones = var.deploy_nodes ? toset([for n in local.control_plane_nodes : n.zone]) : toset([])
}

resource "google_compute_region_health_check" "this" {
  for_each = local.lb_listeners

  name                = "${var.cluster_name}-${each.key}"
  description         = "${each.value.listener} on port ${each.value.port}"
  region              = local.region
  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 2

  dynamic "tcp_health_check" {
    for_each = each.value.health.type == "tcp" ? [1] : []

    content {
      port = each.value.health.port
    }
  }

  dynamic "http_health_check" {
    for_each = each.value.health.type == "http" ? [1] : []

    content {
      port         = each.value.health.port
      request_path = each.value.health.path
    }
  }
}

resource "google_compute_instance_group" "control_plane" {
  for_each = local.control_plane_zones

  name        = "${var.cluster_name}-cp-${each.key}"
  description = "Control planes of ${var.cluster_name} in ${each.key}"
  zone        = each.key
  network     = local.network_id

  # Members are google_compute_instance_group_membership.control_plane.
  lifecycle {
    ignore_changes = [instances]
  }
}

# Deleting an instance drops it from the group, and a replacement keeps the same
# self_link, so an in-place `instances` update adds nothing back: one membership
# per control plane, recreated with its instance.
resource "google_compute_instance_group_membership" "control_plane" {
  for_each = { for n in local.control_plane_nodes : n.hostname => n if var.deploy_nodes }

  zone           = each.value.zone
  instance_group = google_compute_instance_group.control_plane[each.value.zone].name
  instance       = google_compute_instance.control_plane[each.key].self_link

  lifecycle {
    replace_triggered_by = [google_compute_instance.control_plane[each.key]]
  }
}

resource "google_compute_region_backend_service" "this" {
  for_each = local.lb_listeners

  name                  = "${var.cluster_name}-${each.key}"
  description           = "${each.value.listener} on port ${each.value.port}"
  region                = local.region
  load_balancing_scheme = each.value.scheme
  protocol              = "TCP"
  network               = each.value.scheme == "INTERNAL" ? local.network_id : null
  health_checks         = [google_compute_region_health_check.this[each.key].id]
  # The 300 s default delays each membership removal (serialised) by ~6 min.
  connection_draining_timeout_sec = 0

  dynamic "backend" {
    for_each = google_compute_instance_group.control_plane

    content {
      group          = backend.value.self_link
      balancing_mode = "CONNECTION"
    }
  }
}

resource "google_compute_forwarding_rule" "this" {
  for_each = local.lb_listeners

  name                  = "${var.cluster_name}-${each.key}"
  description           = "${each.value.listener} on port ${each.value.port}"
  region                = local.region
  load_balancing_scheme = each.value.scheme
  ip_protocol           = "TCP"
  ports                 = [tostring(each.value.port)]
  ip_address            = each.value.scheme == "INTERNAL" ? google_compute_address.internal_lb.address : google_compute_address.external_lb.address
  backend_service       = google_compute_region_backend_service.this[each.key].id
  network               = each.value.scheme == "INTERNAL" ? local.network_id : null
  subnetwork            = each.value.scheme == "INTERNAL" ? local.subnetwork_id : null
  labels                = merge(local.labels, { "elemental-role" = "lb", "elemental-listener" = each.value.listener })
}
