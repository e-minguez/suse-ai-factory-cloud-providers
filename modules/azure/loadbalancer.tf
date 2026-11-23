# One public Standard load balancer for the API (6443, 9345) and ingress (80,
# 443), created before the image: its static address is in the image. Backends
# are the control-plane NICs (nodes.tf). The frontend keeps the client address
# (floating IP off), so the NSGs filter api_cidrs and ingress_cidrs. Outbound
# SNAT is off: the NAT gateway carries egress. Control-plane hairpin: ADR 015.

resource "azurerm_public_ip" "lb" {
  depends_on = [terraform_data.limits_check]

  name                = "${var.cluster_name}-lb"
  location            = local.region
  resource_group_name = local.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = null
  tags                = merge(local.labels, { "elemental-role" = "lb" })

  # Zone-redundant by default in a region with zones; the API's answer is not a plan input.
  lifecycle {
    ignore_changes = [zones]
  }
}

resource "azurerm_lb" "this" {
  depends_on = [terraform_data.limits_check]

  name                = "${var.cluster_name}-lb"
  location            = local.region
  resource_group_name = local.resource_group_name
  sku                 = "Standard"
  tags                = merge(local.labels, { "elemental-role" = "lb" })

  frontend_ip_configuration {
    name                 = "frontend"
    public_ip_address_id = azurerm_public_ip.lb.id
  }
}

resource "azurerm_lb_backend_address_pool" "control_plane" {
  name            = "control-plane"
  loadbalancer_id = azurerm_lb.this.id
}

locals {
  lb_ports = merge(module.rke2_ports.lb_api, module.rke2_ports.lb_ingress)

  # TCP probe of the API port for both API rules; ingress rules use the check rke2-ports defines.
  lb_probes = merge(
    { api = { protocol = "Tcp", port = 6443, path = null } },
    { for k, h in module.rke2_ports.lb_ingress_health : k => {
      protocol = title(h.type), port = h.port, path = h.path
    } },
  )
}

resource "azurerm_lb_probe" "this" {
  for_each = local.lb_probes

  name                = each.key
  loadbalancer_id     = azurerm_lb.this.id
  protocol            = each.value.protocol
  port                = each.value.port
  request_path        = each.value.path
  interval_in_seconds = 10
  probe_threshold     = 2
}

# Frontend port = backend port. One rule per port; the API rules share the 6443 probe.
resource "azurerm_lb_rule" "this" {
  for_each = local.lb_ports

  name                           = replace(each.key, "_", "-")
  loadbalancer_id                = azurerm_lb.this.id
  protocol                       = "Tcp"
  frontend_port                  = each.value.from
  backend_port                   = each.value.from
  frontend_ip_configuration_name = "frontend"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.control_plane.id]
  probe_id                       = azurerm_lb_probe.this[contains(keys(module.rke2_ports.lb_api), each.key) ? "api" : each.key].id
  floating_ip_enabled            = false
  disable_outbound_snat          = true
  tcp_reset_enabled              = true
  idle_timeout_in_minutes        = 30
}
