run "traefik" {
  command = plan

  variables {
    ingress_controller = "traefik"
  }

  assert {
    condition     = toset(keys(output.control_plane)) == toset(["kube_api", "supervisor", "etcd", "kubelet", "vxlan", "nodeport", "http", "https", "ingress_ping"])
    error_message = "control_plane ports wrong for traefik"
  }

  assert {
    condition     = output.control_plane.etcd.from == 2379 && output.control_plane.etcd.to == 2381
    error_message = "etcd range wrong"
  }

  assert {
    condition     = toset(keys(output.worker)) == toset(["kubelet", "vxlan", "nodeport"])
    error_message = "workers must have no API, supervisor, etcd or ingress ports"
  }

  assert {
    condition     = toset(keys(output.lb_api)) == toset(["kube_api", "supervisor"])
    error_message = "lb_api ports wrong"
  }

  assert {
    condition     = toset(keys(output.lb_ingress)) == toset(["http", "https"])
    error_message = "lb_ingress ports wrong"
  }

  assert {
    condition     = output.lb_ingress_health.http.port == 8080 && output.lb_ingress_health.https.path == "/ping"
    error_message = "traefik health check must be /ping on 8080"
  }
}

run "ingress_nginx" {
  command = plan

  variables {
    ingress_controller = "ingress-nginx"
  }

  assert {
    condition     = contains(keys(output.control_plane), "http") && !contains(keys(output.control_plane), "ingress_ping")
    error_message = "8080 must only be open for traefik"
  }

  assert {
    condition     = output.lb_ingress_health.http.type == "tcp" && output.lb_ingress_health.http.port == 80 && output.lb_ingress_health.https.port == 443
    error_message = "ingress-nginx health checks must be TCP on 80/443"
  }
}

run "none" {
  command = plan

  variables {
    ingress_controller = "none"
  }

  assert {
    condition     = length(output.lb_ingress) == 0 && length(output.control_plane_ingress) == 0 && length(output.lb_ingress_health) == 0
    error_message = "no ingress ports expected without an ingress controller"
  }

  assert {
    condition     = toset(keys(output.control_plane)) == toset(["kube_api", "supervisor", "etcd", "kubelet", "vxlan", "nodeport"])
    error_message = "control_plane ports wrong for none"
  }
}

run "invalid" {
  command = plan

  variables {
    ingress_controller = "bogus"
  }

  expect_failures = [var.ingress_controller]
}
