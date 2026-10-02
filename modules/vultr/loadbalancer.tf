# 6443 admits api_cidrs. 9345 (node join) admits the NAT gateway public IPs,
# where the join of a vpc_only node arrives, plus the public /32s of agent nodes
# (lb_supervisor_extra_cidrs, pass 2). Sources are CIDRs; a bare address never matches.
locals {
  lb_api_firewall = concat(
    [for c in var.api_cidrs : { port = 6443, source = c }],
    [for c in concat([for ip in vultr_nat_gateway.this.public_ips : "${ip}/32"], var.lb_supervisor_extra_cidrs) : { port = 9345, source = c }],
  )
}

# RKE2 API and supervisor. Created before the jumphost because its address is
# baked into the image. Backends come from lb_backend_instance_ids (pass 2): a
# reference to the control plane would close a dependency cycle.
resource "vultr_load_balancer" "api" {
  region              = var.region
  label               = "${var.cluster_name}-api-lb"
  balancing_algorithm = "leastconn"
  vpc                 = vultr_vpc.this.id
  nodes               = local.lb_nodes

  # Vultr returns attached_instances sorted; sorting here avoids a diff that
  # never converges.
  attached_instances = sort(var.lb_backend_instance_ids)

  forwarding_rules {
    frontend_protocol = "tcp"
    frontend_port     = 6443
    backend_protocol  = "tcp"
    backend_port      = 6443
  }

  forwarding_rules {
    frontend_protocol = "tcp"
    frontend_port     = 9345
    backend_protocol  = "tcp"
    backend_port      = 9345
  }

  # TCP check: the API port speaks TLS. A TCP check returns an empty path while
  # the provider defaults it to "/", so path is ignored (docs/providers/vultr.md
  # #load-balancers); protocol and port changes still plan.
  health_check {
    protocol = "tcp"
    port     = 6443
    path     = "/"
  }

  lifecycle {
    ignore_changes = [health_check[0].path]
  }

  # Waits for the address; see data.http.lb below.
  provisioner "local-exec" {
    command = "${path.module}/scripts/wait-for-lb-ipv4.sh"
    environment = {
      LB_ID           = self.id
      TIMEOUT_SECONDS = 600
      POLL_SECONDS    = 10
      VULTR_API_KEY   = var.vultr_api_key
    }
  }

  dynamic "firewall_rules" {
    for_each = local.lb_api_firewall
    content {
      port    = firewall_rules.value.port
      ip_type = "v4"
      source  = firewall_rules.value.source
    }
  }
}

# Ingress on 80/443, separate from the API load balancer because proxy_protocol
# and the health check are per load balancer (docs/providers/vultr.md
# #load-balancers). Same backends as the API one (Traefik runs on the control
# planes). Traefik only: proxy protocol and the /ping:8080 check pair with its
# HelmChartConfig. Created before the jumphost: its address is in the image.
resource "vultr_load_balancer" "ingress" {
  count = var.ingress_controller == "traefik" ? 1 : 0

  region              = var.region
  label               = "${var.cluster_name}-ingress-lb"
  balancing_algorithm = "leastconn"
  vpc                 = vultr_vpc.this.id
  nodes               = local.lb_nodes

  # sort() for the same reason as the API LB above.
  attached_instances = sort(var.lb_backend_instance_ids)

  # Real client addresses; Traefik trusts PROXY headers from the VPC CIDR.
  proxy_protocol = true

  # TCP, not HTTP: Traefik terminates TLS itself and the LB has no certificate.
  dynamic "forwarding_rules" {
    for_each = [80, 443]
    content {
      frontend_protocol = "tcp"
      frontend_port     = forwarding_rules.value
      backend_protocol  = "tcp"
      backend_port      = forwarding_rules.value
    }
  }

  # Traefik /ping on hostPort 8080. Ports 80/443 expect a PROXY header, which
  # the health checker does not send.
  health_check {
    protocol = "http"
    port     = 8080
    path     = "/ping"
  }

  dynamic "firewall_rules" {
    for_each = { for pair in setproduct([80, 443], var.ingress_cidrs) : "${pair[0]}-${pair[1]}" => pair }
    content {
      port    = firewall_rules.value[0]
      ip_type = "v4"
      source  = firewall_rules.value[1]
    }
  }

  # Waits for the address; see data.http.lb below.
  provisioner "local-exec" {
    command = "${path.module}/scripts/wait-for-lb-ipv4.sh"
    environment = {
      LB_ID           = self.id
      TIMEOUT_SECONDS = 600
      POLL_SECONDS    = 10
      VULTR_API_KEY   = var.vultr_api_key
    }
  }
}

# Each LB's public IPv4 from the API, not the resource attribute, which can be
# empty after create. The ids go through terraform_data.lb_ids so the read stays
# at plan time on pass 2. See docs/providers/vultr.md#load-balancers.
resource "terraform_data" "lb_ids" {
  input = merge(
    { api = vultr_load_balancer.api.id },
    var.ingress_controller == "traefik" ? { ingress = vultr_load_balancer.ingress[0].id } : {},
  )
}

data "http" "lb" {
  # Keys are known at plan time; only the ids can be unknown.
  for_each = { for k in keys(terraform_data.lb_ids.input) : k => terraform_data.lb_ids.output[k] }

  url = "https://api.vultr.com/v2/load-balancers/${each.value}"
  request_headers = {
    Accept        = "application/json"
    Authorization = "Bearer ${var.vultr_api_key}"
  }

  retry {
    attempts = 2
  }

  # No postcondition (it would depend on the LBs); the address check is a
  # precondition on random_id.serve_path (build.tf).
}

locals {
  lb_ipv4 = { for k, d in data.http.lb : k => try(jsondecode(d.response_body).load_balancer.ipv4, "") }
  api_vip = local.lb_ipv4["api"]
}
