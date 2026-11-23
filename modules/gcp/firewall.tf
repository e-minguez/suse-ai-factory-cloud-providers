# Firewall rules by network tag: <cluster>-jumphost, <cluster>-control-plane and
# <cluster>-agent. Rules carry no labels; their names start with the cluster
# name. The jumphost is the only SSH entry. The passthrough load balancers keep
# the client address, so the rules name the clients themselves.

module "rke2_ports" {
  source = "../rke2-ports"

  ingress_controller = var.ingress_controller
}

locals {
  tags = {
    jumphost      = "${var.cluster_name}-jumphost"
    control_plane = "${var.cluster_name}-control-plane"
    agent         = "${var.cluster_name}-agent"
  }

  # Probe sources of the passthrough load balancers: external ones (209.85.x)
  # and internal ones (130.211.0.0/22), plus 35.191.0.0/16 for both.
  # https://cloud.google.com/load-balancing/docs/health-check-concepts#ip-ranges
  health_check_ranges = ["35.191.0.0/16", "130.211.0.0/22", "209.85.152.0/22", "209.85.204.0/22"]

  api_ports     = [for k, v in module.rke2_ports.lb_api : tostring(v.from)]
  ingress_ports = [for k, v in module.rke2_ports.lb_ingress : tostring(v.from)]
  health_ports = distinct(concat(
    local.api_ports,
    local.ingress_ports,
    [for k, h in module.rke2_ports.lb_ingress_health : tostring(h.port)],
  ))

  # Nodes dial the external address through Cloud NAT, so its address is a client
  # too (an existing network lists it in nat_ips); nodes with a public address bypass NAT and arrive from that address.
  node_client_cidrs = concat([for ip in local.egress_ips : "${ip}/32"], [
    for h, i in google_compute_instance.node : "${i.network_interface[0].access_config[0].nat_ip}/32"
    if length(i.network_interface[0].access_config) > 0
  ])

  # Ports between cluster members: kubelet, VXLAN, node ports (control plane and agents alike).
  node_ports = module.rke2_ports.worker

  firewall_rules = merge(
    {
      jumphost-ssh = {
        description = "SSH to the jumphost from admin_cidrs"
        sources     = { ranges = var.admin_cidrs, tags = [] }
        targets     = [local.tags["jumphost"]]
        allow       = [{ protocol = "tcp", ports = ["22"] }]
      }
      nodes-ssh = {
        description = "SSH from the jumphost to nodes"
        sources     = { ranges = [], tags = [local.tags["jumphost"]] }
        targets     = [local.tags["control_plane"], local.tags["agent"]]
        allow       = [{ protocol = "tcp", ports = ["22"] }]
      }
      cluster-nodes = {
        description = "Kubelet, VXLAN and node ports between cluster members"
        sources     = { ranges = [], tags = [local.tags["control_plane"], local.tags["agent"]] }
        targets     = [local.tags["control_plane"], local.tags["agent"]]
        allow = concat(
          [for k, p in local.node_ports : {
            protocol = p.protocol
            ports    = [p.from == p.to ? tostring(p.from) : "${p.from}-${p.to}"]
          }],
          [{ protocol = "icmp", ports = [] }],
        )
      }
      control-plane-api = {
        description = "Kubernetes API and RKE2 supervisor from nodes (internal load balancer)"
        sources     = { ranges = [], tags = [local.tags["control_plane"], local.tags["agent"]] }
        targets     = [local.tags["control_plane"]]
        allow       = [{ protocol = "tcp", ports = local.api_ports }]
      }
      control-plane-etcd = {
        description = "etcd between control planes"
        sources     = { ranges = [], tags = [local.tags["control_plane"]] }
        targets     = [local.tags["control_plane"]]
        allow = [{
          protocol = "tcp"
          ports    = ["${module.rke2_ports.control_plane["etcd"].from}-${module.rke2_ports.control_plane["etcd"].to}"]
        }]
      }
      lb-api = {
        description = "Kubernetes API through the external load balancer from api_cidrs and the nodes (NAT or public address)"
        sources     = { ranges = concat(var.api_cidrs, local.node_client_cidrs), tags = [] }
        targets     = [local.tags["control_plane"]]
        allow       = [{ protocol = "tcp", ports = ["6443"] }]
      }
      lb-health = {
        description = "Load balancer health checks"
        sources     = { ranges = local.health_check_ranges, tags = [] }
        targets     = [local.tags["control_plane"]]
        allow       = [{ protocol = "tcp", ports = local.health_ports }]
      }
    },
    length(local.ingress_ports) == 0 ? {} : {
      lb-ingress = {
        description = "Ingress through the external load balancer from ingress_cidrs and the nodes (NAT or public address)"
        sources     = { ranges = concat(var.ingress_cidrs, local.node_client_cidrs), tags = [] }
        targets     = [local.tags["control_plane"]]
        allow       = [{ protocol = "tcp", ports = local.ingress_ports }]
      }
    },
  )
}

resource "google_compute_firewall" "this" {
  for_each = local.firewall_rules

  name          = "${var.cluster_name}-${each.key}"
  description   = each.value.description
  network       = local.network_id
  direction     = "INGRESS"
  priority      = 1000
  source_ranges = length(each.value.sources.ranges) == 0 ? null : each.value.sources.ranges
  source_tags   = length(each.value.sources.tags) == 0 ? null : each.value.sources.tags
  target_tags   = each.value.targets

  dynamic "allow" {
    for_each = each.value.allow

    content {
      protocol = allow.value.protocol
      ports    = length(allow.value.ports) == 0 ? null : allow.value.ports
    }
  }
}
