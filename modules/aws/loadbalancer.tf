# Two Network Load Balancers, each with its own security group (immutable on
# aws_lb: changing it replaces the load balancer).
#
# The API NLB address is chosen at plan time (local.api_vip), and the target
# group attachments are separate resources, so the load balancers never
# reference aws_instance and no second apply is needed.
#
# Load balancer and target group names are capped at 32 characters; the
# cluster_name limit is checked in network.tf.

# --- api: internal NLB, the elemental apiVIP -----------------------------

resource "aws_lb" "api" {
  name               = "${var.cluster_name}-api"
  internal           = true
  load_balancer_type = "network"
  security_groups    = [aws_security_group.api_nlb.id]

  enable_cross_zone_load_balancing = true

  # subnet_mapping pins a static private IP: the first subnet gets the apiVIP,
  # the others get an auto-assigned address so every zone has an ENI.
  dynamic "subnet_mapping" {
    for_each = aws_subnet.private

    content {
      subnet_id            = subnet_mapping.value.id
      private_ipv4_address = subnet_mapping.key == 0 ? local.api_vip : null
    }
  }

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-api-nlb"
    "elemental-role" = "lb"
  })
}

# preserve_client_ip = false: control-plane nodes dial the NLB they are
# targets of, and client-IP preservation makes that connection hairpin and drop.
resource "aws_lb_target_group" "api_kube_api" {
  name        = "${var.cluster_name}-api-6443"
  port        = 6443
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = aws_vpc.this.id

  preserve_client_ip = false

  health_check {
    protocol = "TCP"
    port     = "6443"
  }

  tags = merge(local.common_tags, {
    Name                 = "${var.cluster_name}-api-6443"
    "elemental-role"     = "lb"
    "elemental-listener" = "kube_api"
  })
}

resource "aws_lb_target_group" "api_supervisor" {
  name        = "${var.cluster_name}-api-9345"
  port        = 9345
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = aws_vpc.this.id

  preserve_client_ip = false

  # Health-checked on 6443: the supervisor port only listens once the node has
  # joined, so checking it would stall the join.
  health_check {
    protocol = "TCP"
    port     = "6443"
  }

  tags = merge(local.common_tags, {
    Name                 = "${var.cluster_name}-api-9345"
    "elemental-role"     = "lb"
    "elemental-listener" = "supervisor"
  })
}

resource "aws_lb_listener" "api_kube_api" {
  load_balancer_arn = aws_lb.api.arn
  port              = 6443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api_kube_api.arn
  }

  tags = merge(local.common_tags, {
    "elemental-role"     = "lb"
    "elemental-listener" = "kube_api"
  })
}

resource "aws_lb_listener" "api_supervisor" {
  load_balancer_arn = aws_lb.api.arn
  port              = 9345
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api_supervisor.arn
  }

  tags = merge(local.common_tags, {
    "elemental-role"     = "lb"
    "elemental-listener" = "supervisor"
  })
}

# --- public: internet-facing NLB, ingress + admin kubectl ------------------

resource "aws_lb" "public" {
  name               = "${var.cluster_name}-public"
  internal           = false
  load_balancer_type = "network"
  security_groups    = [aws_security_group.public_nlb.id]
  subnets            = aws_subnet.public[*].id

  enable_cross_zone_load_balancing = true

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-public-nlb"
    "elemental-role" = "lb"
  })
}

# proxy_protocol_v2 must match the Traefik HelmChartConfig, which trusts the VPC CIDR.
resource "aws_lb_target_group" "http" {
  count = var.ingress_controller == "none" ? 0 : 1

  name        = "${var.cluster_name}-http"
  port        = 80
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = aws_vpc.this.id

  proxy_protocol_v2 = var.ingress_controller == "traefik"

  # From rke2-ports: Traefik's plain /ping entrypoint (8080), since 80/443
  # require a PROXY header the NLB checker does not send; TCP 80/443 otherwise.
  health_check {
    protocol = "TCP"
    port     = tostring(module.rke2_ports.lb_ingress_health.http.port)
  }

  tags = merge(local.common_tags, {
    Name                 = "${var.cluster_name}-http"
    "elemental-role"     = "lb"
    "elemental-listener" = "http"
  })
}

resource "aws_lb_target_group" "https" {
  count = var.ingress_controller == "none" ? 0 : 1

  name        = "${var.cluster_name}-https"
  port        = 443
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = aws_vpc.this.id

  proxy_protocol_v2 = var.ingress_controller == "traefik"

  health_check {
    protocol = "TCP"
    port     = tostring(module.rke2_ports.lb_ingress_health.https.port)
  }

  tags = merge(local.common_tags, {
    Name                 = "${var.cluster_name}-https"
    "elemental-role"     = "lb"
    "elemental-listener" = "https"
  })
}

resource "aws_lb_listener" "http" {
  count = var.ingress_controller == "none" ? 0 : 1

  load_balancer_arn = aws_lb.public.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.http[0].arn
  }

  tags = merge(local.common_tags, {
    "elemental-role"     = "lb"
    "elemental-listener" = "http"
  })
}

resource "aws_lb_listener" "https" {
  count = var.ingress_controller == "none" ? 0 : 1

  load_balancer_arn = aws_lb.public.arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.https[0].arn
  }

  tags = merge(local.common_tags, {
    "elemental-role"     = "lb"
    "elemental-listener" = "https"
  })
}

# kubectl from api_cidrs (enforced by the public NLB security group),
# carried on the ingress NLB. Kept when ingress_controller is "none".
resource "aws_lb_target_group" "admin_kube_api" {
  name        = "${var.cluster_name}-admin-6443"
  port        = 6443
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = aws_vpc.this.id

  preserve_client_ip = false

  health_check {
    protocol = "TCP"
    port     = "6443"
  }

  tags = merge(local.common_tags, {
    Name                 = "${var.cluster_name}-admin-6443"
    "elemental-role"     = "lb"
    "elemental-listener" = "kube_api"
  })
}

resource "aws_lb_listener" "admin_kube_api" {
  load_balancer_arn = aws_lb.public.arn
  port              = 6443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.admin_kube_api.arn
  }

  tags = merge(local.common_tags, {
    "elemental-role"     = "lb"
    "elemental-listener" = "kube_api"
  })
}

# --- target group attachments ---------------------------------------------

# All five target groups point at the control-plane nodes; GPU nodes are never targets.
locals {
  lb_targets = var.deploy_nodes ? { for n in local.control_plane_nodes : n.hostname => n } : {}
}

# depends_on the instances: an ip target is a plain string, so without it the
# registration can race subnet creation and fail with "not within a VPC subnet".
resource "aws_lb_target_group_attachment" "api_kube_api" {
  for_each = local.lb_targets

  depends_on = [aws_instance.control_plane]

  target_group_arn  = aws_lb_target_group.api_kube_api.arn
  target_id         = each.value.private_ip
  port              = 6443
  availability_zone = local.az_names[each.value.az_index]
}

resource "aws_lb_target_group_attachment" "api_supervisor" {
  for_each = local.lb_targets

  depends_on = [aws_instance.control_plane]

  target_group_arn  = aws_lb_target_group.api_supervisor.arn
  target_id         = each.value.private_ip
  port              = 9345
  availability_zone = local.az_names[each.value.az_index]
}

resource "aws_lb_target_group_attachment" "http" {
  for_each = var.ingress_controller == "none" ? {} : local.lb_targets

  depends_on = [aws_instance.control_plane]

  target_group_arn  = aws_lb_target_group.http[0].arn
  target_id         = each.value.private_ip
  port              = 80
  availability_zone = local.az_names[each.value.az_index]
}

resource "aws_lb_target_group_attachment" "https" {
  for_each = var.ingress_controller == "none" ? {} : local.lb_targets

  depends_on = [aws_instance.control_plane]

  target_group_arn  = aws_lb_target_group.https[0].arn
  target_id         = each.value.private_ip
  port              = 443
  availability_zone = local.az_names[each.value.az_index]
}

resource "aws_lb_target_group_attachment" "admin_kube_api" {
  for_each = local.lb_targets

  depends_on = [aws_instance.control_plane]

  target_group_arn  = aws_lb_target_group.admin_kube_api.arn
  target_id         = each.value.private_ip
  port              = 6443
  availability_zone = local.az_names[each.value.az_index]
}
