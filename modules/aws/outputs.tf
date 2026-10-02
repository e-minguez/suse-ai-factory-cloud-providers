# The output set is identical in every provider module (docs/conventions.md#outputs).
# Values with no AWS counterpart are null; AWS-only data is in provider_details.

locals {
  rancher_enabled = contains(module.elemental_config.enabled_components, "rancher")

  # Not yet in S3 and not registered as an AMI: the image is still being built.
  build_in_progress = local.build_ami && local.effective_ami_id == null

  jumphost_access = {
    public_ip  = try(aws_instance.jumphost[0].public_ip, null)
    private_ip = try(aws_instance.jumphost[0].private_ip, null)
    ssh_user   = var.jumphost_username != "" ? var.jumphost_username : "root"
  }

  build_status_value = {
    method     = "s3"
    url_or_key = "s3://${aws_s3_bucket.build.id}/${local.raw_image_key}"
    hosts      = compact([try(aws_instance.jumphost[0].private_ip, null)])
  }

  next_steps_header = [
    "Kubernetes API : https://${local.admin_api_host}:6443",
  ]

  next_steps_rancher = local.rancher_enabled ? [
    "Rancher        : https://${local.rancher_hostname}",
    "                 password: terraform -chdir=${local.cluster_dir} output -raw rancher_bootstrap_password",
  ] : []

  next_steps_access = [
    "Kubeconfig     : ${local.helper["kubeconfig"]} -o ~/.kube/${var.cluster_name}.yaml   (admin credential, mode 600)",
    "SSH            : ${local.helper["ssh"]} <node>   nodes: terraform -chdir=${local.cluster_dir} output nodes",
  ]

  next_steps_building = [
    "Image build    : in progress; follow it with ${local.helper["build-logs"]}",
  ]

  next_steps_no_nodes = [
    "Nodes          : not deployed (deploy_nodes = false); set it to true and apply again",
    "Build logs     : ${local.helper["build-logs"]}",
  ]

  next_steps_lines = concat(
    local.next_steps_header,
    local.next_steps_rancher,
    local.build_in_progress ? local.next_steps_building : !var.deploy_nodes ? local.next_steps_no_nodes : local.next_steps_access,
  )
}

output "provider" {
  description = "Provider name, for tools that dispatch on it."
  value       = "aws"
}

output "cluster_name" {
  description = "Cluster name, the prefix of resource names and node hostnames."
  value       = var.cluster_name
}

output "region" {
  description = "AWS region of the cluster."
  value       = var.region
}

output "kubernetes_api_endpoint" {
  description = "Kubernetes API URL, https://<api_host>:6443."
  value       = "https://${local.admin_api_host}:6443"
}

output "api_host" {
  description = "Hostname of the Kubernetes API for kubectl: api_host when set, else the public NLB DNS name (6443 open to api_cidrs)."
  value       = local.admin_api_host
}

output "api_vip" {
  description = "Static private IPv4 of the internal NLB, baked into every node's config as network.apiVIP."
  value       = local.api_vip
}

output "ingress_endpoint" {
  description = "HTTPS URL of the public ingress NLB. Null when ingress_controller is \"none\"."
  value       = var.ingress_controller == "none" ? null : "https://${aws_lb.public.dns_name}"
}

output "rancher_url" {
  description = "Rancher UI URL. Null when \"rancher\" is not in components."
  value       = local.rancher_enabled ? "https://${local.rancher_hostname}" : null
}

output "rancher_hostname" {
  description = "Hostname of the Rancher ingress. Null when \"rancher\" is not in components."
  value       = local.rancher_enabled ? local.rancher_hostname : null
}

output "rancher_bootstrap_password" {
  description = "Rancher's initial admin password. Null when \"rancher\" is not in components."
  value       = local.rancher_enabled ? module.elemental_config.rancher_bootstrap_password : null
  sensitive   = true
}

output "jumphost" {
  description = "Build host and SSH bastion into the private nodes; ssh_user is root when jumphost_username is empty. The IPs are null when image_id is set."
  value       = local.jumphost_access
}

output "nodes" {
  description = "Cluster nodes keyed by hostname. Empty when deploy_nodes is false."
  value = {
    for n in local.cluster_nodes : n.hostname => {
      role          = n.role
      pool          = n.pool
      init          = n.init
      zone          = local.zones[n.az_index]
      private_ip    = n.role == "control_plane" ? n.private_ip : aws_instance.agent[n.hostname].private_ip
      public_ip     = null
      instance_type = n.instance_type
      id            = n.role == "control_plane" ? aws_instance.control_plane[n.hostname].id : aws_instance.agent[n.hostname].id
      ssh_user      = var.node_username
    } if var.deploy_nodes
  }
}

output "image" {
  description = "Image build_id and the AMI ID keyed by region. The map is empty while the AMI does not exist."
  value = {
    build_id = module.elemental_config.build_id
    rebuild  = var.image_rebuild
    ids      = tomap({ for r in [var.region] : r => local.effective_ami_id if local.effective_ami_id != null })
  }
}

output "egress_ips" {
  description = "Public source IPs of cluster egress: the NAT gateway Elastic IP."
  value       = [aws_eip.nat.public_ip]
}

output "network" {
  description = "VPC CIDR and the CIDRs of all subnets (public first, then private, one per zone)."
  value = {
    vpc_cidr     = local.vpc_cidr
    subnet_cidrs = concat(local.public_subnet_cidrs, local.private_subnet_cidrs)
  }
}

output "build_status" {
  description = "Where the image build is followed while it runs; null once the AMI exists or when image_id is set."
  value       = local.build_in_progress ? local.build_status_value : null
}

output "next_steps" {
  description = "Human-readable hints for reaching the cluster after the apply."
  value       = join("\n", local.next_steps_lines)
}

output "provider_details" {
  description = "AWS-only data: vpc_id, subnet ids, internal_api_host (the nodes' API name), build_bucket (as sensitive as state) and ami_name."
  value = {
    vpc_id             = aws_vpc.this.id
    public_subnet_ids  = aws_subnet.public[*].id
    private_subnet_ids = aws_subnet.private[*].id
    internal_api_host  = local.api_host
    build_bucket       = aws_s3_bucket.build.id
    ami_name           = local.ami_name
  }
}
