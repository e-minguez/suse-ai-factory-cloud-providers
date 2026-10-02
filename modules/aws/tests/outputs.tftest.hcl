# Asserts the docs/conventions.md#outputs output set: every name exists with the right
# shape, and removed outputs are gone. Mock providers only; no cloud calls.

variables {
  region                  = "us-east-1"
  admin_cidrs             = ["198.51.100.0/24"]
  root_password_hash      = "$6$DUMMYSALT$ROOTDUMMYHASHROOTDUMMYHASHROOTDUMMYHASHROOTDUMMYHASHROOTDUMMYHASH0"
  node_user_password_hash = "$6$DUMMYSALT$NODEDUMMYHASHNODEDUMMYHASHNODEDUMMYHASHNODEDUMMYHASHNODEDUMMYHASH0"
  ssh_authorized_keys     = ["ssh-ed25519 AAAADUMMY test"]
  cluster_name            = "out-aws"
  rancher_hostname        = "rancher.example.com"
  zones                   = ["a", "b"]
  control_plane_count     = 3
  image_id                = "ami-0dummyprebuilt00001"
  appco_username          = "DUMMY-APPCO-USER"
  appco_password          = "DUMMY-APPCO-PASSWORD"
  suse_registry_username  = "DUMMY-REGCODE"
  suse_registry_password  = "DUMMY-REGISTRY-PASSWORD"
  nvidia_api_key          = "DUMMY-NVIDIA-API-KEY"
}

mock_provider "aws" {
  override_data {
    target = data.aws_availability_zones.available
    values = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }

  override_data {
    target = data.aws_ec2_instance_type_offerings.this
    values = {
      instance_types = ["m7i.xlarge"]
    }
  }

  override_resource {
    target = aws_lb.api
    values = {
      dns_name = "internal-dummy-api-nlb-1234567890.elb.us-east-1.amazonaws.com"
      arn      = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/net/dummy-api/0000000000000001"
    }
  }

  override_resource {
    target = aws_lb.public
    values = {
      dns_name = "dummy-public-nlb-0987654321.elb.us-east-1.amazonaws.com"
      arn      = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/net/dummy-public/0000000000000002"
    }
  }

  # aws_lb_listener validates load_balancer_arn/target_group_arn look like
  # real ARNs client-side, even against a mocked provider -- the mock
  # default for a computed "arn" attribute is not ARN-shaped, so every
  # target group needs one too.
  override_resource {
    target = aws_lb_target_group.api_kube_api
    values = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/dummy-api-6443/0000000000000003" }
  }

  override_resource {
    target = aws_lb_target_group.api_supervisor
    values = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/dummy-api-9345/0000000000000004" }
  }

  override_resource {
    target = aws_lb_target_group.http
    values = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/dummy-http/0000000000000005" }
  }

  override_resource {
    target = aws_lb_target_group.https
    values = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/dummy-https/0000000000000006" }
  }

  override_resource {
    target = aws_lb_target_group.admin_kube_api
    values = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/dummy-admin-6443/0000000000000007" }
  }

  override_resource {
    target = aws_s3_bucket.build
    values = {
      id = "dummy-build-bucket-000000"
    }
  }

  # These four are aws_iam_policy_document data sources: normally computed
  # locally by the provider (no API call), but under mock_provider they still
  # need an override -- the default mock value for a computed string
  # attribute is "", and aws_iam_role/aws_iam_role_policy's schema validates
  # assume_role_policy/policy as parseable JSON client-side even against a
  # mocked provider, so "" fails plan with "not a JSON object".
  override_data {
    target = data.aws_iam_policy_document.vmimport_trust
    values = {
      json = jsonencode({ Version = "2012-10-17", Statement = [] })
    }
  }

  override_data {
    target = data.aws_iam_policy_document.vmimport
    values = {
      json = jsonencode({ Version = "2012-10-17", Statement = [] })
    }
  }

  override_data {
    target = data.aws_iam_policy_document.jumphost_trust
    values = {
      json = jsonencode({ Version = "2012-10-17", Statement = [] })
    }
  }

  override_data {
    target = data.aws_iam_policy_document.jumphost
    values = {
      json = jsonencode({ Version = "2012-10-17", Statement = [] })
    }
  }
}

mock_provider "aws" {
  alias = "nodes"
}

mock_provider "random" {
  override_resource {
    target = random_password.token
    values = {
      result = "DUMMYTOKENDUMMYTOKENDUMMYTOKEN12"
    }
  }

  override_resource {
    target = module.elemental_config.random_password.rancher_bootstrap
    values = {
      result = "DUMMY-RANCHER-BOOTSTRAP-PW"
    }
  }
}

override_resource {
  target = time_static.created
  values = { rfc3339 = "2026-09-30T12:34:56Z" }
}

run "output_set" {
  command = apply

  # A missing output name fails as an unknown reference.
  assert {
    condition = length([
      output.provider, output.cluster_name, output.region, output.kubernetes_api_endpoint,
      output.api_host, output.api_vip, output.ingress_endpoint, output.rancher_url,
      output.rancher_hostname, output.jumphost, output.nodes, output.image,
      output.egress_ips, output.network, output.build_status, output.next_steps,
      output.provider_details,
    ]) == 17
    error_message = "A required output is missing."
  }

  assert {
    condition     = nonsensitive(output.rancher_bootstrap_password) != null
    error_message = "rancher_bootstrap_password must be set when Rancher is enabled."
  }

  assert {
    condition     = output.provider == "aws" && output.cluster_name == "out-aws" && output.region == "us-east-1"
    error_message = "provider, cluster_name or region is wrong."
  }

  assert {
    condition     = startswith(output.kubernetes_api_endpoint, "https://") && endswith(output.kubernetes_api_endpoint, ":6443") && output.api_host == regex("^https://(.*):6443$", output.kubernetes_api_endpoint)[0]
    error_message = "kubernetes_api_endpoint must be https://<api_host>:6443."
  }

  assert {
    condition     = can(cidrhost("${output.api_vip}/32", 0))
    error_message = "api_vip must be an IPv4 address."
  }

  assert {
    condition     = output.rancher_url == "https://rancher.example.com" && output.rancher_hostname == "rancher.example.com"
    error_message = "rancher_url and rancher_hostname must follow rancher_hostname."
  }

  assert {
    condition     = startswith(output.ingress_endpoint, "https://")
    error_message = "ingress_endpoint must be an https URL with the default ingress_controller."
  }

  assert {
    condition     = alltrue([for k in ["public_ip", "private_ip", "ssh_user"] : contains(keys(output.jumphost), k)]) && output.jumphost.ssh_user == "suse"
    error_message = "jumphost must carry public_ip, private_ip and ssh_user."
  }

  assert {
    condition     = length(output.nodes) == 3 && length([for h, n in output.nodes : h if n.init]) == 1
    error_message = "nodes must hold the 3 control planes with exactly one init node."
  }

  assert {
    condition = alltrue([
      for h, n in output.nodes : alltrue([
        for k in ["role", "pool", "init", "zone", "private_ip", "public_ip", "instance_type", "id", "ssh_user"] : contains(keys(n), k)
      ]) && n.role == "control_plane" && n.ssh_user == "suse"
    ])
    error_message = "Every node needs role, pool, init, zone, private_ip, public_ip, instance_type, id and ssh_user."
  }

  assert {
    condition     = length(output.image.ids) == 1 && output.image.ids["us-east-1"] == "ami-0dummyprebuilt00001" && length(output.image.build_id) == 12
    error_message = "image must be { build_id, ids = { region = ami } }."
  }

  assert {
    condition     = length(output.egress_ips) == 1
    error_message = "egress_ips must list the NAT gateway address."
  }

  assert {
    condition     = output.network.vpc_cidr == "10.20.0.0/20" && length(output.network.subnet_cidrs) == 4
    error_message = "network must be { vpc_cidr, subnet_cidrs } with one public and one private subnet per zone."
  }

  assert {
    condition     = output.build_status == null
    error_message = "build_status must be null when image_id is set."
  }

  assert {
    condition     = strcontains(output.next_steps, "/scripts/kubeconfig.sh -C ") && strcontains(output.next_steps, "/scripts/ssh.sh -C ") && !strcontains(output.next_steps, "build-logs.sh")
    error_message = "next_steps must point to the kubeconfig and ssh scripts."
  }

  assert {
    condition     = alltrue([for k in ["vpc_id", "public_subnet_ids", "private_subnet_ids", "build_bucket", "ami_name"] : contains(keys(output.provider_details), k)])
    error_message = "provider_details is missing a key."
  }
}

run "no_nodes" {
  command = apply

  variables {
    deploy_nodes = false
  }

  assert {
    condition     = length(output.nodes) == 0 && strcontains(output.next_steps, "build-logs.sh") && !strcontains(output.next_steps, "kubeconfig.sh")
    error_message = "deploy_nodes = false must give an empty nodes map and a build-logs hint."
  }
}

run "no_rancher_no_ingress" {
  command = apply

  variables {
    components         = ["local-path-provisioner"]
    ingress_controller = "none"
  }

  assert {
    condition     = output.rancher_url == null && output.rancher_hostname == null && output.ingress_endpoint == null
    error_message = "Rancher and ingress outputs must be null when disabled."
  }
}

run "rancher_hostname_default" {
  command = apply

  variables {
    rancher_hostname = null
  }

  assert {
    condition     = output.rancher_hostname != null && output.rancher_url == "https://${output.rancher_hostname}"
    error_message = "A null rancher_hostname must fall back to the public NLB DNS name."
  }
}

run "build_access_in_state" {
  command = plan

  variables {
    image_id       = null
    jumphost_image = "ami-0dummyjumphost0001"
  }

  assert {
    condition     = terraform_data.build_access[0].input.build_id == output.image.build_id && terraform_data.build_access[0].input.jumphost.ssh_user == output.jumphost.ssh_user && terraform_data.build_access[0].input.build_status.method == "s3"
    error_message = "terraform_data.build_access must carry the build_id, jumphost and build_status that scripts/lib/ssh.sh reads mid-apply."
  }
}

run "rebuild_counter_baseline" {
  command = plan

  assert {
    condition     = output.image.rebuild == 0
    error_message = "image.rebuild must default to 0."
  }
}

run "rebuild_counter_changes_build_id" {
  command = plan

  variables {
    image_rebuild = 1
  }

  assert {
    condition     = output.image.rebuild == 1 && output.image.build_id != run.rebuild_counter_baseline.image.build_id
    error_message = "Bumping image_rebuild must change image.build_id and be reported in image.rebuild."
  }
}

run "managed_labels" {
  command = plan

  variables {
    tags = { env = "test" }
  }

  assert {
    condition = alltrue([for k in ["cluster", "managed-by", "module", "created"] : contains(keys(aws_vpc.this.tags), "elemental-${k}")]) && (
      aws_vpc.this.tags["elemental-cluster"] == "out-aws" &&
      aws_vpc.this.tags["elemental-managed-by"] == "terraform" &&
      aws_vpc.this.tags["elemental-module"] == "ai-factory" &&
      can(regex("^[0-9]{8}-[0-9]{6}$", aws_vpc.this.tags["elemental-created"])) &&
      aws_vpc.this.tags["elemental-created"] == "20260930-123456" &&
      aws_vpc.this.tags["env"] == "test"
    )
    error_message = "Managed tags must carry the four elemental.suse.com keys (created as UTC YYYYMMDD-hhmmss) plus var.tags."
  }
}

run "labels_follow_convention" {
  command = plan

  variables {
    worker_pools = {
      cpu = { instance_type = "m7i.xlarge", count = 1 }
    }
    gpu_pools = {
      a10 = { instance_type = "g5.2xlarge", count = 1 }
    }
  }

  assert {
    condition = length(aws_instance.control_plane) == 3 && alltrue([
      for k, i in aws_instance.control_plane :
      i.tags["elemental-role"] == "control_plane" && i.tags["elemental-pool"] == "cp" && contains(keys(i.tags), "elemental-build")
    ])
    error_message = "Control-plane instances must carry role=control_plane, pool=cp and a build label."
  }

  assert {
    condition = (
      aws_instance.agent["out-aws-cpu-01"].tags["elemental-role"] == "worker" &&
      aws_instance.agent["out-aws-cpu-01"].tags["elemental-pool"] == "cpu" &&
      contains(keys(aws_instance.agent["out-aws-cpu-01"].tags), "elemental-build") &&
      aws_instance.agent["out-aws-a10-01"].tags["elemental-role"] == "gpu" &&
      aws_instance.agent["out-aws-a10-01"].tags["elemental-pool"] == "a10" &&
      contains(keys(aws_instance.agent["out-aws-a10-01"].tags), "elemental-build")
    )
    error_message = "Worker and GPU instances must carry role worker/gpu, their pool and a build label."
  }

  assert {
    condition = (
      aws_security_group.agent[0].tags["elemental-role"] == "agent" &&
      aws_security_group.control_plane.tags["elemental-role"] == "control_plane" &&
      aws_lb.api.tags["elemental-role"] == "lb" &&
      aws_lb_listener.api_kube_api.tags["elemental-listener"] == "kube_api" &&
      aws_lb_target_group.api_supervisor.tags["elemental-listener"] == "supervisor"
    )
    error_message = "Security groups, NLBs, listeners and target groups must carry role and listener labels."
  }

  assert {
    condition = !anytrue(concat(
      [for k, i in aws_instance.control_plane : contains(keys(i.tags), "elemental-component")],
      [for k, i in aws_instance.agent : contains(keys(i.tags), "elemental-component")],
      [contains(keys(aws_security_group.agent[0].tags), "elemental-component")],
      [contains(keys(aws_lb.api.tags), "elemental-component")],
    ))
    error_message = "The component label no longer exists."
  }
}

run "tags_reject_managed_prefix" {
  command = plan

  variables {
    tags = { "elemental-role" = "x" }
  }

  expect_failures = [var.tags]
}

run "single_node_keeps_load_balancers" {
  command = apply

  variables {
    control_plane_count = 1
  }

  assert {
    condition     = length(aws_instance.control_plane) == 1 && length(output.nodes) == 1 && output.nodes["out-aws-cp-01"].init
    error_message = "control_plane_count = 1 must create exactly one control-plane node, the init node."
  }

  assert {
    condition     = aws_lb.api.id != null && aws_lb.public.id != null
    error_message = "A single-node cluster must keep the API and ingress load balancers."
  }
}

run "even_control_plane_count_rejected" {
  command = plan

  variables {
    control_plane_count = 2
  }

  expect_failures = [var.control_plane_count]
}

run "suse_storage_single_node_rejected" {
  command = plan

  variables {
    control_plane_count = 1
    components          = ["rancher", "suse-storage", "aif-operator"]
  }

  expect_failures = [var.suse_storage_nodes]
}

run "suse_storage_on_gpu_needs_three_workers" {
  command = plan

  variables {
    components         = ["rancher", "suse-storage", "aif-operator"]
    suse_storage_nodes = ["gpu"]
    gpu_pools          = {}
  }

  expect_failures = [var.suse_storage_nodes]
}

run "worker_pools_only" {
  command = apply

  variables {
    worker_pools = {
      cpu = { instance_type = "m7i.xlarge", count = 2 }
    }
  }

  assert {
    condition     = length([for h, n in output.nodes : h if n.role == "worker" && n.pool == "cpu"]) == 2
    error_message = "worker_pools must create 2 nodes with role worker and pool cpu."
  }

  assert {
    condition     = length([for h, n in output.nodes : h if n.role == "gpu"]) == 0
    error_message = "No gpu nodes expected without gpu_pools."
  }

  assert {
    condition     = contains(keys(output.nodes), "out-aws-cpu-01") && contains(keys(output.nodes), "out-aws-cpu-02")
    error_message = "Worker hostnames must be <cluster_name>-<pool>-NN."
  }
}

run "worker_and_gpu_pools" {
  command = apply

  variables {
    worker_pools = {
      cpu = { instance_type = "m7i.xlarge", count = 2 }
    }
    gpu_pools = {
      a10 = { instance_type = "g5.2xlarge", count = 1 }
    }
  }

  assert {
    condition = (
      length([for h, n in output.nodes : h if n.role == "worker"]) == 2 &&
      length([for h, n in output.nodes : h if n.role == "gpu"]) == 1 &&
      length([for h, n in output.nodes : h if n.role == "control_plane"]) == 3
    )
    error_message = "Expected 3 control_plane, 2 worker and 1 gpu nodes."
  }
}

run "worker_gpu_key_collision_rejected" {
  command = plan

  variables {
    worker_pools = {
      shared = { instance_type = "m7i.xlarge" }
    }
    gpu_pools = {
      shared = { instance_type = "g5.2xlarge" }
    }
  }

  expect_failures = [var.worker_pools]
}

run "suse_storage_on_workers_accepted" {
  command = plan

  variables {
    control_plane_count = 1
    components          = ["rancher", "suse-storage", "aif-operator"]
    suse_storage_nodes  = ["control_plane", "worker"]
    worker_pools = {
      cpu = { instance_type = "m7i.xlarge", count = 2 }
    }
  }
}

run "suse_storage_on_pool_accepted" {
  command = plan

  variables {
    control_plane_count = 1
    components          = ["rancher", "suse-storage", "aif-operator"]
    suse_storage_nodes  = ["control_plane", "storage"]
    worker_pools = {
      storage = { instance_type = "m7i.xlarge", count = 2 }
      general = { instance_type = "m7i.xlarge", count = 1 }
    }
  }
}

# One control plane plus a one-node pool: the other pool does not count.
run "suse_storage_on_pool_counts_only_that_pool" {
  command = plan

  variables {
    control_plane_count = 1
    components          = ["rancher", "suse-storage", "aif-operator"]
    suse_storage_nodes  = ["control_plane", "storage"]
    worker_pools = {
      storage = { instance_type = "m7i.xlarge", count = 1 }
      general = { instance_type = "m7i.xlarge", count = 3 }
    }
  }

  expect_failures = [var.suse_storage_nodes]
}

run "suse_storage_unknown_pool_rejected" {
  command = plan

  variables {
    suse_storage_nodes = ["control_plane", "nosuchpool"]
  }

  expect_failures = [var.suse_storage_nodes]
}

run "worker_pool_named_gpu_rejected" {
  command = plan

  variables {
    worker_pools = { gpu = { instance_type = "m7i.xlarge", count = 1 } }
  }

  expect_failures = [var.worker_pools]
}

run "api_host_is_public_nlb" {
  command = apply

  assert {
    condition     = output.api_host == "dummy-public-nlb-0987654321.elb.us-east-1.amazonaws.com" && output.provider_details.internal_api_host == "internal-dummy-api-nlb-1234567890.elb.us-east-1.amazonaws.com"
    error_message = "api_host must default to the public NLB; nodes keep the internal one."
  }
}

run "public_nlb_reaches_kube_api" {
  command = apply

  assert {
    condition     = aws_vpc_security_group_ingress_rule.control_plane_from_public_nlb["kube_api"].from_port == 6443
    error_message = "The control plane must accept 6443 from the public NLB (admin kubectl listener)."
  }
}

run "api_cidrs_restrict_public_kube_api" {
  command = plan

  variables {
    api_cidrs = ["192.0.2.0/24"]
  }

  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.public_nlb["api-192.0.2.0/24"].from_port == 6443 &&
      length([for k, r in aws_vpc_security_group_ingress_rule.public_nlb : k if r.from_port == 6443]) == 1
    )
    error_message = "The public NLB must admit 6443 from api_cidrs only."
  }
}
