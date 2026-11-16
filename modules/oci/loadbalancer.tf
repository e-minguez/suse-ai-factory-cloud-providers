# One public NLB for the API (6443, 9345) and ingress (80, 443). Created before
# the image: its reserved address is in the image (apiVIP, api_host, Rancher
# hostname). Backends are separate resources added with the nodes (control
# planes only: Traefik and the API server run there). The NLB listener and
# backend set objects carry no tags.

# Reserved, so the address survives a replaced NLB.
resource "oci_core_public_ip" "nlb" {
  depends_on = [terraform_data.limits_check]

  compartment_id = var.oci_compartment_ocid
  lifetime       = "RESERVED"
  display_name   = "${var.cluster_name}-lb"
  freeform_tags  = merge(local.labels, { "elemental-role" = "lb" })

  # The NLB attaches the IP to its own private IP; resetting it would detach it.
  lifecycle {
    ignore_changes = [private_ip_id]
  }
}

resource "oci_network_load_balancer_network_load_balancer" "this" {
  depends_on = [terraform_data.limits_check]

  compartment_id             = var.oci_compartment_ocid
  display_name               = "${var.cluster_name}-lb"
  subnet_id                  = local.public_subnet_id
  is_private                 = false
  network_security_group_ids = [local.nsg_ids["nlb"]]
  freeform_tags              = merge(local.labels, { "elemental-role" = "lb" })

  reserved_ips {
    id = oci_core_public_ip.nlb.id
  }
}

locals {
  lb_ports = merge(module.rke2_ports.lb_api, module.rke2_ports.lb_ingress)

  # TCP checks for the API ports (TLS); ingress ports use the check rke2-ports defines.
  lb_health = merge(
    { for k, v in module.rke2_ports.lb_api : k => { protocol = "TCP", port = v.from, path = null } },
    { for k, h in module.rke2_ports.lb_ingress_health : k => {
      protocol = upper(h.type), port = h.port, path = h.path
    } },
  )
}

# No listener preserves the client address: control planes dial the NLB they back
# (through the NAT gateway), and a preserved source would make the reply skip the
# NLB. The NLB's own NSG filters api_cidrs and ingress_cidrs (firewall.tf).

resource "oci_network_load_balancer_backend_set" "this" {
  for_each = local.lb_ports

  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.this.id
  name                     = replace(each.key, "_", "-")
  policy                   = contains(keys(module.rke2_ports.lb_api), each.key) ? "FIVE_TUPLE" : "TWO_TUPLE"
  is_preserve_source       = false

  health_checker {
    protocol           = local.lb_health[each.key].protocol
    port               = local.lb_health[each.key].port
    url_path           = local.lb_health[each.key].path
    return_code        = local.lb_health[each.key].protocol == "HTTP" ? 200 : null
    interval_in_millis = 10000
    timeout_in_millis  = 5000
    retries            = 2
  }
}

resource "oci_network_load_balancer_listener" "this" {
  for_each = local.lb_ports

  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.this.id
  name                     = replace(each.key, "_", "-")
  default_backend_set_name = oci_network_load_balancer_backend_set.this[each.key].name
  port                     = each.value.from
  protocol                 = "TCP"
}

# Every listener's backend set holds the control planes. The instances are
# targets by OCID; the backend port is the listener port.
locals {
  lb_backends = var.deploy_nodes ? merge([
    for k, v in local.lb_ports : {
      for n in local.control_plane_nodes : "${k}/${n.hostname}" => { set = k, hostname = n.hostname, port = v.from }
    }
  ]...) : {}
}

resource "oci_network_load_balancer_backend" "this" {
  for_each = local.lb_backends

  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.this.id
  backend_set_name         = oci_network_load_balancer_backend_set.this[each.value.set].name
  target_id                = oci_core_instance.node[each.value.hostname].id
  port                     = each.value.port
}
