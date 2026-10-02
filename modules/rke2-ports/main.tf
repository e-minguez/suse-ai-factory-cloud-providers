# Canonical port matrix per node role. Pure data: each provider reshapes the
# maps into its own security group or firewall rule format.

locals {
  api = {
    kube_api   = { protocol = "tcp", from = 6443, to = 6443 }
    supervisor = { protocol = "tcp", from = 9345, to = 9345 }
  }

  # Ports a worker accepts; the control plane accepts the same set from it.
  # Agents only dial out to the API, so no 6443/9345 here.
  node = {
    kubelet  = { protocol = "tcp", from = 10250, to = 10250 }
    vxlan    = { protocol = "udp", from = 8472, to = 8472 }
    nodeport = { protocol = "tcp", from = 30000, to = 32767 }
  }

  etcd = {
    etcd = { protocol = "tcp", from = 2379, to = 2381 }
  }

  # hostPorts of the ingress controller, bound on control-plane nodes only.
  # 8080 is Traefik's /ping entrypoint, used by the ingress load balancer check.
  ingress = merge(
    var.ingress_controller == "none" ? {} : {
      http  = { protocol = "tcp", from = 80, to = 80 }
      https = { protocol = "tcp", from = 443, to = 443 }
    },
    var.ingress_controller != "traefik" ? {} : {
      ingress_ping = { protocol = "tcp", from = 8080, to = 8080 }
    },
  )
}
