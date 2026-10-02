# Asserts the common output set (docs/conventions.md#outputs) exists with the right
# types and that rke2_token is not an output. Plan only, evroc mocked.

mock_provider "evroc" {
  override_during = plan
}
mock_provider "http" {}

override_data {
  target = module.config.data.http.aif_release_manifest
  values = {
    status_code   = 200
    response_body = file("../elemental-config/tests/fixtures/release_manifest.yaml")
  }
}

override_resource {
  target = evroc_public_ip.cluster
  values = { ip_address = "203.0.113.10" }
}

override_resource {
  target = evroc_public_ip.jumphost
  values = { ip_address = "203.0.113.11" }
}

override_resource {
  target = evroc_virtual_machine.jumphost
  values = {
    private_ipv4_address = "10.20.0.5"
    public_ipv4_address  = "203.0.113.11"
  }
}

override_data {
  target = data.evroc_compute_profiles.this
  values = {
    profiles = ["c1a.m", "a1a.m", "gn-l40s.s"]
    details = [
      { name = "c1a.m", vcpus = 4, memory_amount = 16, memory_unit = "GB", gpu_model = "", gpu_quantity = 0 },
      { name = "a1a.m", vcpus = 4, memory_amount = 16, memory_unit = "GB", gpu_model = "", gpu_quantity = 0 },
      { name = "gn-l40s.s", vcpus = 16, memory_amount = 64, memory_unit = "GB", gpu_model = "AD102GL_L40S", gpu_quantity = 1 },
    ]
  }
}

override_data {
  target = data.evroc_organization_quota.this
  values = {
    compute_vcpus         = 1000
    compute_memory        = "4000GB"
    networking_public_ips = 100
    usage_vcpus           = 0
    usage_memory          = "0GB"
    usage_public_ips      = 0
  }
}

variables {
  admin_cidrs                = ["198.51.100.0/24"]
  ssh_authorized_keys        = ["ssh-ed25519 AAAADUMMY test"]
  root_password_hash         = "$6$SALT$ROOT"
  node_user_password_hash    = "$6$SALT$NODE"
  appco_username             = "appco-user"
  appco_password             = "appco-pass"
  suse_registry_username     = "REGCODE"
  suse_registry_password     = "registry-pass"
  nvidia_api_key             = "nvidia-key"
  rancher_bootstrap_password = "bootstrap-pass"
  rancher_hostname           = null
  region                     = "se-sto"
  gpu_pools                  = { inference = { instance_type = "gn-l40s.s", count = 1 } }
  image_ids                  = { a = "SNAP-a", b = "SNAP-b", c = "SNAP-c" }
}

override_resource {
  target = time_static.created
  values = { rfc3339 = "2026-09-30T12:34:56Z" }
}

run "common_output_set" {
  command = apply

  variables {
    image_ready = true
  }

  # Referencing an undeclared output fails the run. Applies only with image_ids set, so no wait script runs.
  assert {
    condition = alltrue([
      output.provider == output.provider,
      output.cluster_name == output.cluster_name,
      output.region == output.region,
      output.kubernetes_api_endpoint == output.kubernetes_api_endpoint,
      output.api_host == output.api_host,
      output.api_vip == output.api_vip,
      output.ingress_endpoint == output.ingress_endpoint,
      output.rancher_url == output.rancher_url,
      output.rancher_hostname == output.rancher_hostname,
      output.rancher_bootstrap_password == output.rancher_bootstrap_password,
      output.jumphost == output.jumphost,
      output.nodes == output.nodes,
      output.image == output.image,
      output.egress_ips == output.egress_ips,
      output.network == output.network,
      output.build_status == output.build_status,
      output.next_steps == output.next_steps,
      output.provider_details == output.provider_details,
    ])
    error_message = "output set differs from docs/conventions.md#outputs"
  }

  assert {
    condition     = output.provider == "evroc" && output.region == "se-sto"
    error_message = "provider/region wrong"
  }

  assert {
    condition     = output.kubernetes_api_endpoint == "https://${output.api_host}:6443"
    error_message = "kubernetes_api_endpoint must use api_host"
  }

  assert {
    condition     = output.api_host == "rke2-203.0.113.10.sslip.io" && output.api_vip == "203.0.113.10"
    error_message = "api_host/api_vip wrong"
  }

  assert {
    condition     = can(tostring(output.ingress_endpoint)) && can(tostring(output.rancher_url)) && can(tostring(output.rancher_hostname))
    error_message = "ingress_endpoint, rancher_url, rancher_hostname must be strings"
  }

  assert {
    condition     = alltrue([for k in ["public_ip", "private_ip", "ssh_user"] : contains(keys(output.jumphost), k)])
    error_message = "jumphost needs public_ip, private_ip, ssh_user"
  }

  assert {
    condition     = can(tomap(output.nodes)) && can(tolist(output.egress_ips))
    error_message = "nodes must be a map and egress_ips a list"
  }

  assert {
    condition     = alltrue([for k in ["build_id", "ids"] : contains(keys(output.image), k)]) && toset(keys(output.image.ids)) == toset(["a", "b", "c"])
    error_message = "image needs build_id and ids keyed by zone"
  }

  assert {
    condition     = alltrue([for k in ["vpc_cidr", "subnet_cidrs"] : contains(keys(output.network), k)])
    error_message = "network needs vpc_cidr and subnet_cidrs"
  }

  assert {
    condition     = output.build_status == null
    error_message = "build_status must be null once the image exists"
  }

  assert {
    condition     = strcontains(output.next_steps, "/scripts/kubeconfig.sh -C ") && strcontains(output.next_steps, "/scripts/ssh.sh -C ")
    error_message = "next_steps must point at the shared scripts"
  }

  assert {
    condition     = can(tomap(output.provider_details)) || can(keys(output.provider_details))
    error_message = "provider_details must be an object"
  }
}

run "build_in_progress" {
  command = plan

  variables {
    image_ready = false
    image_ids   = {}
  }

  assert {
    condition     = output.build_status != null && output.build_status.method == "relay"
    error_message = "build_status must describe the relay while building"
  }

  assert {
    condition     = length(output.build_status.hosts) >= 1
    error_message = "build_status.hosts must list the jumphost and builders"
  }

  assert {
    condition     = strcontains(output.next_steps, "build-logs.sh")
    error_message = "next_steps must point at build-logs.sh during a build"
  }
}

run "build_access_in_state" {
  command = plan

  variables {
    image_ready = false
    image_ids   = {}
  }

  assert {
    condition     = length(terraform_data.build_access) == 1 && terraform_data.build_access[0].input.jumphost.ssh_user == output.jumphost.ssh_user && terraform_data.build_access[0].input.build_status.method == "relay" && terraform_data.build_access[0].input.build_id == output.image.build_id
    error_message = "terraform_data.build_access must carry the build_id, jumphost and build_status that scripts/lib/ssh.sh reads mid-apply."
  }
}

run "build_access_kept_after_build" {
  command = plan

  variables {
    image_ready = true
    image_ids   = {}
  }

  assert {
    condition     = length(terraform_data.build_access) == 1 && output.build_status == null
    error_message = "build_access stays while no image is adopted; the build_status output is null once image_ready."
  }
}

run "build_access_absent_with_image_ids" {
  command = plan

  assert {
    condition     = length(terraform_data.build_access) == 0
    error_message = "Adopted image_ids mean no build: build_access must not exist."
  }
}

run "adopted_image_ids_no_build" {
  command = apply

  variables {
    image_ready = false
  }

  assert {
    condition     = output.build_status == null && !strcontains(output.next_steps, "build-logs.sh")
    error_message = "adopted image_ids mean no build: build_status null, no build-logs hint"
  }

  assert {
    condition     = alltrue([for n in values(output.nodes) : n.pool == "cp" if n.role == "control_plane"])
    error_message = "control-plane nodes must report pool \"cp\""
  }

  assert {
    condition     = alltrue([for n in values(output.nodes) : n.ssh_user == var.node_username])
    error_message = "every node must report ssh_user = node_username"
  }
}

run "rebuild_counter_baseline" {
  command = apply

  variables {
    image_ready = true
  }

  assert {
    condition     = output.image.rebuild == 0
    error_message = "image.rebuild must default to 0."
  }
}

run "rebuild_counter_changes_build_id" {
  command = apply

  variables {
    image_ready   = true
    image_rebuild = 1
  }

  assert {
    condition     = output.image.rebuild == 1 && output.image.build_id != run.rebuild_counter_baseline.image.build_id
    error_message = "Bumping image_rebuild must change image.build_id and be reported in image.rebuild."
  }
}

run "quota_limit_short" {
  command = plan

  variables {
    image_ready = false
    image_ids   = {}
  }

  override_data {
    target = data.evroc_organization_quota.this
    values = {
      compute_vcpus         = 15
      compute_memory        = "4000GB"
      networking_public_ips = 100
      usage_vcpus           = 0
      usage_memory          = "0GB"
      usage_public_ips      = 0
    }
  }

  expect_failures = [evroc_vpc.this]
}

run "managed_labels" {
  command = apply

  variables {
    image_ready = true
    tags        = { env = "test" }
  }

  assert {
    condition = alltrue([for k in ["cluster", "managed-by", "module", "created"] : contains(keys(evroc_public_ip.cluster.user_labels), "elemental-${k}")]) && (
      evroc_public_ip.cluster.user_labels["elemental-cluster"] == var.cluster_name &&
      evroc_public_ip.cluster.user_labels["elemental-managed-by"] == "terraform" &&
      evroc_public_ip.cluster.user_labels["elemental-module"] == "ai-factory" &&
      can(regex("^[0-9]{8}-[0-9]{6}$", evroc_public_ip.cluster.user_labels["elemental-created"])) &&
      evroc_public_ip.cluster.user_labels["elemental-created"] == "20260930-123456" &&
      evroc_public_ip.cluster.user_labels["env"] == "test"
    )
    error_message = "Labels must carry the four elemental- keys (created as UTC YYYYMMDD-hhmmss) plus var.tags."
  }
}

run "single_node_keeps_load_balancer" {
  command = apply

  variables {
    image_ready         = true
    control_plane_count = 1
  }

  assert {
    condition     = length(evroc_virtual_machine.control_plane) == 1 && length([for n in values(output.nodes) : n if n.role == "control_plane" && n.init]) == 1
    error_message = "control_plane_count = 1 must create exactly one control-plane node, the init node."
  }

  assert {
    condition     = evroc_loadbalancer.cluster.id != null && length(evroc_lb_backend_service.cluster) > 0
    error_message = "A single-node cluster must keep the load balancer and its services."
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
    image_ready  = true
    gpu_pools    = {}
    worker_pools = { general = { instance_type = "c1a.m", count = 2, zone = "b" } }
  }

  assert {
    condition = (
      length([for n in values(output.nodes) : n if n.role == "worker" && n.pool == "general"]) == 2 &&
      length([for n in values(output.nodes) : n if n.role == "gpu"]) == 0 &&
      length(evroc_security_group.agent) == 1 &&
      alltrue([for n in values(output.nodes) : n.zone == "b" if n.role == "worker"])
    )
    error_message = "worker_pools must yield role worker nodes with their pool name, in the pool's zone, using the worker security group."
  }

  assert {
    condition     = evroc_disk.agent["${var.cluster_name}-general-01"].user_labels["elemental-role"] == "worker"
    error_message = "Worker disks must carry role worker."
  }
}

run "placement_pool_with_several_nodes" {
  command = apply

  variables {
    image_ready  = true
    gpu_pools    = { inference = { instance_type = "gn-l40s.s", count = 2, placement = "spread" } }
    worker_pools = { empty = { instance_type = "c1a.m", count = 0, placement = "spread" } }
  }

  assert {
    condition     = keys(evroc_placement_group.agent) == ["inference/a"]
    error_message = "A pool with placement gets one placement group however many nodes it has, and an empty pool none."
  }
}

run "worker_and_gpu_pools" {
  command = apply

  variables {
    image_ready  = true
    worker_pools = { general = { instance_type = "c1a.m", count = 2 } }
  }

  assert {
    condition = (
      length([for n in values(output.nodes) : n if n.role == "worker"]) == 2 &&
      length([for n in values(output.nodes) : n if n.role == "gpu"]) == 1 &&
      length(evroc_virtual_machine.agent) == 3
    )
    error_message = "Worker and GPU pools must share one agent VM set with distinct roles."
  }
}

run "worker_gpu_key_collision_rejected" {
  command = plan

  variables {
    worker_pools = { inference = { instance_type = "c1a.m", count = 1 } }
  }

  expect_failures = [var.worker_pools]
}

run "suse_storage_on_workers_accepted" {
  command = plan

  variables {
    control_plane_count = 1
    gpu_pools           = {}
    worker_pools        = { general = { instance_type = "c1a.m", count = 2 } }
    suse_storage_nodes  = ["control_plane", "worker"]
    components          = ["rancher", "suse-storage", "aif-operator"]
  }
}

run "labels_follow_convention" {
  command = apply

  variables {
    image_ready         = true
    control_plane_count = 3
    worker_pools        = { general = { instance_type = "c1a.m", count = 1 } }
  }

  assert {
    condition = alltrue([
      for k, vm in evroc_virtual_machine.control_plane :
      vm.user_labels["elemental-role"] == "control_plane" &&
      vm.user_labels["elemental-pool"] == "cp" &&
      contains(keys(vm.user_labels), "elemental-build")
    ]) && length(evroc_virtual_machine.control_plane) == 3
    error_message = "Control-plane VMs must carry role control_plane, pool cp and build."
  }

  assert {
    condition = (
      evroc_virtual_machine.agent["${var.cluster_name}-general-01"].user_labels["elemental-role"] == "worker" &&
      evroc_virtual_machine.agent["${var.cluster_name}-general-01"].user_labels["elemental-pool"] == "general" &&
      contains(keys(evroc_virtual_machine.agent["${var.cluster_name}-general-01"].user_labels), "elemental-build") &&
      evroc_disk.agent["${var.cluster_name}-general-01"].user_labels["elemental-pool"] == "general"
    )
    error_message = "Worker VMs and disks must carry role worker and their pool; VMs also build."
  }

  assert {
    condition = (
      evroc_virtual_machine.agent["${var.cluster_name}-inference-01"].user_labels["elemental-role"] == "gpu" &&
      evroc_virtual_machine.agent["${var.cluster_name}-inference-01"].user_labels["elemental-pool"] == "inference"
    )
    error_message = "GPU VMs must carry role gpu and their pool."
  }

  assert {
    condition     = evroc_security_group.agent[0].user_labels["elemental-role"] == "agent"
    error_message = "The shared worker/GPU security group must carry role agent."
  }

  assert {
    condition = (
      evroc_loadbalancer.cluster.user_labels["elemental-role"] == "lb" &&
      evroc_public_ip.cluster.user_labels["elemental-role"] == "lb"
    )
    error_message = "The load balancer and its VIP must carry role lb."
  }

  assert {
    condition = alltrue([
      for k, s in evroc_lb_backend_service.cluster :
      s.user_labels["elemental-listener"] == k && s.user_labels["elemental-role"] == "lb"
    ]) && contains(keys(evroc_lb_backend_service.cluster), "kube_api")
    error_message = "Backend services must carry listener = rke2-ports port name and role lb."
  }
}

run "tags_reject_managed_prefix" {
  command = plan

  variables {
    tags = { "elemental-role" = "x" }
  }

  expect_failures = [var.tags]
}

run "tags_reject_slash_in_key" {
  command = plan

  variables {
    tags = { "example.com/team" = "x" }
  }

  expect_failures = [evroc_vpc.this]
}

run "api_cidrs_default_open" {
  command = plan

  assert {
    condition     = evroc_lb_backend_service.cluster["kube_api"].health_check[0].target_port == 6443
    error_message = "With api_cidrs open, the kube_api health check must target 6443."
  }
}

run "api_cidrs_restrict_kube_api" {
  command = plan

  variables {
    api_cidrs = ["192.0.2.0/24"]
  }

  assert {
    condition = (
      sort([for r in evroc_security_group.control_plane.rule : r.remote_ip if r.port == 6443]) == sort(["192.0.2.0/24", output.network.vpc_cidr]) &&
      [for r in evroc_security_group.control_plane.rule : r.remote_ip if r.port == 9345] == ["0.0.0.0/0"]
    )
    error_message = "The control plane must admit 6443 from api_cidrs and the VPC, 9345 from anywhere."
  }

  assert {
    condition     = evroc_lb_backend_service.cluster["kube_api"].health_check[0].target_port == 9345
    error_message = "With api_cidrs narrowed, the kube_api health check must target 9345."
  }
}
