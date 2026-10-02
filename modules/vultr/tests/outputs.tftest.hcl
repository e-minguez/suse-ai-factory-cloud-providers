# Asserts the common output set (docs/conventions.md#outputs) exists with the right
# shape and that rke2_token is not an output. Vultr mocked; no cloud calls.

mock_provider "vultr" {
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

override_data {
  target = data.http.plan_availability
  values = {
    status_code   = 200
    response_body = jsonencode({ available_plans = ["vx1-g-4c-16g-240s", "vc2-6c-16gb"] })
  }
}

override_data {
  target          = data.http.lb
  override_during = plan
  values = {
    status_code   = 200
    response_body = jsonencode({ load_balancer = { ipv4 = "203.0.113.10" } })
  }
}

override_data {
  target          = data.http.agent_existing["instances"]
  override_during = plan
  values = {
    status_code   = 200
    response_body = jsonencode({ instances = [{ label = "out-vultr-gpu-01", plan = "voc-c-4c-8gb-150s-amd", region = "ams" }] })
  }
}

override_data {
  target          = data.http.agent_existing["bare-metals"]
  override_during = plan
  values = {
    status_code   = 200
    response_body = jsonencode({ bare_metals = [] })
  }
}

override_resource {
  target          = vultr_load_balancer.api
  override_during = plan
  values          = { id = "00000000-0000-0000-0000-000000000001" }
}

override_resource {
  target          = vultr_load_balancer.ingress
  override_during = plan
  values          = { id = "00000000-0000-0000-0000-000000000002" }
}

override_resource {
  target          = vultr_instance.jumphost
  override_during = plan
  values = {
    main_ip     = "203.0.113.11"
    internal_ip = "10.20.0.5"
  }
}

variables {
  vultr_api_key           = "DUMMY-VULTR-KEY"
  region                  = "ams"
  admin_cidrs             = ["198.51.100.0/24"]
  root_password_hash      = "$6$DUMMYSALT$ROOTDUMMYHASHROOTDUMMYHASHROOTDUMMYHASHROOTDUMMYHASHROOTDUMMYHASH0"
  node_user_password_hash = "$6$DUMMYSALT$NODEDUMMYHASHNODEDUMMYHASHNODEDUMMYHASHNODEDUMMYHASHNODEDUMMYHASH0"
  ssh_authorized_keys     = ["ssh-ed25519 AAAADUMMY test"]
  cluster_name            = "out-vultr"
  rancher_hostname        = "rancher.example.com"
  control_plane_count     = 3
  appco_username          = "DUMMY-APPCO-USER"
  appco_password          = "DUMMY-APPCO-PASSWORD"
  suse_registry_username  = "DUMMY-REGCODE"
  suse_registry_password  = "DUMMY-REGISTRY-PASSWORD"
  nvidia_api_key          = "DUMMY-NVIDIA-API-KEY"
}

override_resource {
  target          = time_static.created
  override_during = plan
  values          = { rfc3339 = "2026-09-30T12:34:56Z" }
}

run "output_set" {
  command = plan

  # A missing output name fails as an unknown reference.
  assert {
    condition = length([
      output.provider, output.cluster_name, output.region, output.kubernetes_api_endpoint,
      output.api_host, output.api_vip, output.rancher_url, output.rancher_hostname,
      output.jumphost, output.nodes, output.image, output.egress_ips, output.network,
      output.next_steps, output.provider_details, output.ingress_endpoint, output.build_status,
    ]) == 17
    error_message = "A required output is missing."
  }

  assert {
    condition     = output.provider == "vultr" && output.cluster_name == "out-vultr" && output.region == "ams"
    error_message = "provider, cluster_name or region is wrong."
  }

  assert {
    condition     = alltrue([for k in ["public_ip", "private_ip", "ssh_user"] : contains(keys(output.jumphost), k)]) && output.jumphost.ssh_user == "suse"
    error_message = "jumphost must carry public_ip, private_ip and ssh_user."
  }

  assert {
    condition     = length(output.nodes) == 3
    error_message = "nodes must hold the 3 control planes."
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
    condition     = contains(keys(output.image), "build_id") && contains(keys(output.image), "ids")
    error_message = "image must be { build_id, ids }."
  }

  assert {
    condition     = alltrue([for k in ["vpc_cidr", "subnet_cidrs"] : contains(keys(output.network), k)])
    error_message = "network must be { vpc_cidr, subnet_cidrs }."
  }
}

run "zones_at_most_one" {
  command = plan

  variables {
    zones = ["a", "b"]
  }

  expect_failures = [vultr_vpc.this]
}

# build_id is unknown at plan time here (the hash covers the load balancer IP),
# so the hash effect is asserted in elemental-config/tests/build-hash.tftest.hcl.
run "rebuild_counter_reported" {
  command = plan

  variables {
    image_rebuild = 3
  }

  assert {
    condition     = output.image.rebuild == 3
    error_message = "image.rebuild must report image_rebuild."
  }
}

run "build_access_in_state" {
  command = plan

  assert {
    condition     = length(terraform_data.build_access) == 1 && terraform_data.build_access[0].input.jumphost.ssh_user == output.jumphost.ssh_user && terraform_data.build_access[0].input.build_status.method == "http" && length(terraform_data.build_access[0].input.build_status.hosts) == 1
    error_message = "terraform_data.build_access must carry the build_id, jumphost and build_status that scripts/lib/ssh.sh reads mid-apply."
  }
}

run "build_access_absent_with_image_id" {
  command = plan

  variables {
    image_id = "00000000-0000-0000-0000-00000000aaaa"
  }

  assert {
    condition     = length(terraform_data.build_access) == 0
    error_message = "No build runs with image_id set: build_access must not exist."
  }
}

# Stock check (availability.tf). The mocked availability answer lacks the GPU
# plan; the pool is only accepted when its node already exists.
run "gpu_stock_skipped_for_existing_node" {
  command = plan

  variables {
    gpu_pools = { gpu = { instance_type = "voc-c-4c-8gb-150s-amd", count = 1 } }
  }
}

run "gpu_stock_checked_for_new_node" {
  command = plan

  variables {
    gpu_pools = { gpu = { instance_type = "voc-c-4c-8gb-150s-amd", count = 2 } }
  }

  expect_failures = [data.http.plan_availability]
}

run "gpu_stock_skipped_for_empty_pool" {
  command = plan

  variables {
    gpu_pools = { gpu = { instance_type = "voc-c-4c-8gb-150s-amd", count = 0 } }
  }
}

# Same label, different plan: the plan change replaces the node, so it needs
# stock again.
run "gpu_stock_checked_on_plan_change" {
  command = plan

  variables {
    gpu_pools = { gpu = { instance_type = "vc2-2c-4gb", count = 1 } }
  }

  expect_failures = [data.http.plan_availability]
}

# Same label and plan in another region does not count as existing.
run "gpu_stock_checked_for_other_region" {
  command = plan

  variables {
    gpu_pools = { gpu = { instance_type = "voc-c-4c-8gb-150s-amd", count = 1 } }
  }

  override_data {
    target          = data.http.agent_existing["instances"]
    override_during = plan
    values = {
      status_code   = 200
      response_body = jsonencode({ instances = [{ label = "out-vultr-gpu-01", plan = "voc-c-4c-8gb-150s-amd", region = "ewr" }] })
    }
  }

  expect_failures = [data.http.plan_availability]
}

# A vpc_only node's main_ip can read as its VPC address; the flag keeps it out
# of agent_node_cidrs (the LB 9345 firewall) and of nodes[*].public_ip.
run "vpc_only_gpu_node_has_no_public_ip" {
  command = plan

  variables {
    gpu_pools = { gpu = { instance_type = "voc-c-4c-8gb-150s-amd", count = 1 } }
  }

  override_resource {
    target          = vultr_instance.agent_cloud
    override_during = plan
    values = {
      main_ip     = "10.20.0.9"
      internal_ip = "10.20.0.9"
    }
  }

  assert {
    condition     = output.provider_details.agent_node_cidrs == [] && output.nodes["out-vultr-gpu-01"].public_ip == null
    error_message = "A vpc_only GPU node must not appear in agent_node_cidrs or report a public_ip."
  }
}

run "public_gpu_node_reports_public_ip" {
  command = plan

  variables {
    gpu_pools = { gpu = { instance_type = "voc-c-4c-8gb-150s-amd", count = 1, public_ip = true } }
  }

  override_resource {
    target          = vultr_instance.agent_cloud
    override_during = plan
    values = {
      main_ip     = "203.0.113.20"
      internal_ip = "10.20.0.9"
    }
  }

  assert {
    condition     = output.provider_details.agent_node_cidrs == ["203.0.113.20/32"] && output.nodes["out-vultr-gpu-01"].public_ip == "203.0.113.20"
    error_message = "A public GPU node must appear in agent_node_cidrs and report its public_ip."
  }
}

run "managed_labels" {
  command = plan

  variables {
    tags = { env = "test" }
  }

  assert {
    condition = alltrue([for k in ["cluster", "managed-by", "module", "created"] : length([for t in vultr_instance.jumphost.tags : t if startswith(t, "elemental-${k}=")]) == 1]) && (
      contains(vultr_instance.jumphost.tags, "elemental-cluster=${var.cluster_name}") &&
      contains(vultr_instance.jumphost.tags, "elemental-managed-by=terraform") &&
      contains(vultr_instance.jumphost.tags, "elemental-module=ai-factory") &&
      contains(vultr_instance.jumphost.tags, "elemental-created=20260930-123456") &&
      contains(vultr_instance.jumphost.tags, "env=test")
    )
    error_message = "Tags must be key=value strings with the four elemental.suse.com keys (created as UTC YYYYMMDD-hhmmss) plus var.tags."
  }
}

run "single_node_keeps_load_balancers" {
  command = plan

  variables {
    control_plane_count = 1
  }

  assert {
    condition     = length(output.nodes) == 1 && output.nodes["out-vultr-cp-01"].role == "control_plane" && output.nodes["out-vultr-cp-01"].init
    error_message = "control_plane_count = 1 must plan exactly one control-plane node."
  }

  assert {
    condition     = vultr_load_balancer.api.id != null && length(vultr_load_balancer.ingress) == 1
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
  command = plan

  variables {
    worker_pools = { wrk = { instance_type = "vc2-6c-16gb", count = 2 } }
  }

  assert {
    condition = length(output.nodes) == 5 && alltrue([
      for n in ["out-vultr-wrk-01", "out-vultr-wrk-02"] :
      output.nodes[n].role == "worker" && output.nodes[n].pool == "wrk" && !output.nodes[n].init
    ])
    error_message = "worker_pools must plan count nodes with role worker and the pool name."
  }
}

run "worker_and_gpu_pools" {
  command = plan

  variables {
    worker_pools = { wrk = { instance_type = "vc2-6c-16gb", count = 2 } }
    gpu_pools    = { gpu = { instance_type = "voc-c-4c-8gb-150s-amd", count = 1 } }
  }

  assert {
    condition = length(output.nodes) == 6 && (
      length([for n, v in output.nodes : n if v.role == "worker"]) == 2 &&
      length([for n, v in output.nodes : n if v.role == "gpu"]) == 1 &&
      length([for n, v in output.nodes : n if v.role == "control_plane"]) == 3
    )
    error_message = "Worker and GPU pools must coexist with their own roles."
  }
}

run "worker_gpu_key_collision_rejected" {
  command = plan

  variables {
    worker_pools = { same = { instance_type = "vc2-6c-16gb", count = 1 } }
    gpu_pools    = { same = { instance_type = "voc-c-4c-8gb-150s-amd", count = 1 } }
  }

  expect_failures = [var.worker_pools]
}

run "worker_unsupported_fields_rejected" {
  command = plan

  variables {
    worker_pools = { wrk = { instance_type = "vc2-6c-16gb", count = 1, zone = "a" } }
  }

  expect_failures = [vultr_vpc.this]
}

run "worker_stock_checked_for_new_node" {
  command = plan

  variables {
    worker_pools = { wrk = { instance_type = "vc2-2c-4gb", count = 1 } }
  }

  expect_failures = [data.http.plan_availability]
}

run "worker_bare_metal_reports_public_ip" {
  command = plan

  variables {
    worker_pools = { bm = { instance_type = "vbm-6c-32gb-amd", count = 1, kind = "bare_metal" } }
  }

  override_data {
    target          = data.http.plan_availability
    override_during = plan
    values = {
      status_code   = 200
      response_body = jsonencode({ available_plans = ["vx1-g-4c-16g-240s", "vc2-6c-16gb", "vbm-6c-32gb-amd"] })
    }
  }

  override_resource {
    target          = vultr_bare_metal_server.agent
    override_during = plan
    values          = { main_ip = "203.0.113.30" }
  }

  assert {
    condition     = output.nodes["out-vultr-bm-01"].role == "worker" && output.provider_details.agent_node_cidrs == ["203.0.113.30/32"]
    error_message = "A bare metal worker must report role worker and feed agent_node_cidrs."
  }
}

run "suse_storage_on_workers_accepted" {
  command = plan

  variables {
    control_plane_count = 1
    components          = ["rancher", "suse-storage", "aif-operator"]
    suse_storage_nodes  = ["control_plane", "worker"]
    worker_pools        = { wrk = { instance_type = "vc2-6c-16gb", count = 2 } }
  }
}

run "labels_follow_convention" {
  command = plan

  variables {
    worker_pools = { wrk = { instance_type = "vc2-6c-16gb", count = 1 } }
    gpu_pools    = { gpu = { instance_type = "voc-c-4c-8gb-150s-amd", count = 1 } }
  }

  # build_id depends on the load balancer address, unknown at plan: its tag is
  # counted (length 7), not read. Tags come as lists from provider_details
  # because a set with an unknown element is wholly unknown.
  assert {
    condition = alltrue([
      for h, t in output.provider_details.node_tags : (
        anytrue([for x in t : x == "elemental-cluster=out-vultr"]) &&
        anytrue([for x in t : x == "elemental-managed-by=terraform"]) &&
        length(t) == 7
      )
    ])
    error_message = "Every node needs the four managed labels plus role, pool and build."
  }

  assert {
    condition = alltrue([
      for h in ["out-vultr-cp-01", "out-vultr-cp-02", "out-vultr-cp-03"] : (
        anytrue([for x in output.provider_details.node_tags[h] : x == "elemental-role=control_plane"]) &&
        anytrue([for x in output.provider_details.node_tags[h] : x == "elemental-pool=cp"])
      )
    ])
    error_message = "Control planes need role=control_plane and pool=cp."
  }

  assert {
    condition = (
      anytrue([for x in output.provider_details.node_tags["out-vultr-wrk-01"] : x == "elemental-role=worker"]) &&
      anytrue([for x in output.provider_details.node_tags["out-vultr-wrk-01"] : x == "elemental-pool=wrk"]) &&
      anytrue([for x in output.provider_details.node_tags["out-vultr-gpu-01"] : x == "elemental-role=gpu"]) &&
      anytrue([for x in output.provider_details.node_tags["out-vultr-gpu-01"] : x == "elemental-pool=gpu"])
    )
    error_message = "Worker and GPU nodes need their role and pool."
  }

  assert {
    condition = (
      contains(vultr_instance.jumphost.tags, "elemental-role=jumphost") &&
      length([for t in vultr_instance.jumphost.tags : t if startswith(t, "elemental-build=")]) == 0
    )
    error_message = "The jumphost needs role=jumphost and no build label."
  }
}

run "tags_reject_managed_prefix" {
  command = plan

  variables {
    tags = { "elemental-role" = "x" }
  }

  expect_failures = [var.tags]
}

run "api_cidrs_restrict_kube_api" {
  command = plan

  variables {
    api_cidrs = ["192.0.2.0/24"]
  }

  override_resource {
    target          = vultr_nat_gateway.this
    override_during = plan
    values          = { public_ips = ["198.51.100.7"], private_ips = ["10.20.0.1"] }
  }

  assert {
    condition     = [for r in vultr_load_balancer.api.firewall_rules : r.source if r.port == 6443] == ["192.0.2.0/24"]
    error_message = "The API load balancer must admit 6443 from api_cidrs only."
  }
}
