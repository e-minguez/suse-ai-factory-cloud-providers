# Asserts the common output set (docs/conventions.md#outputs), the control
# plane init/join switch, the plan-time input and availability checks, and
# the security group rules. Exoscale mocked; no cloud calls.

mock_provider "exoscale" {
  override_during = plan
}
mock_provider "http" {}
mock_provider "external" {}

override_data {
  target = module.config.data.http.aif_release_manifest
  values = {
    status_code   = 200
    response_body = file("../elemental-config/tests/fixtures/release_manifest.yaml")
  }
}

override_data {
  target          = data.external.api_check
  override_during = plan
  values = {
    result = {
      types = jsonencode({
        "standard.extra-large" = { listed = true, in_zone = true, gpus = 0 }
        "standard.large"       = { listed = true, in_zone = true, gpus = 0 }
        "standard.medium"      = { listed = true, in_zone = true, gpus = 0 }
        "gpu3.small"           = { listed = true, in_zone = true, gpus = 1 }
        "gpua5000.small"       = { listed = true, in_zone = false, gpus = 1 }
        "gpurtx6000pro.small"  = { listed = false, in_zone = false, gpus = 0 }
      })
      quotas = jsonencode({
        instance                = { usage = 0, limit = 20 }
        "network-load-balancer" = { usage = 0, limit = 5 }
        gpu3                    = { usage = 0, limit = 2 }
      })
      existing = jsonencode({ instances = 0, gpus = {}, nlbs = 0 })
    }
  }
}

override_data {
  target          = data.external.cp_members
  override_during = plan
  values = {
    result = {
      members = jsonencode([
        { id = "00000000-0000-0000-0000-0000000000c1", name = "out-exo-cp-abcde-fghij", public_ip = "203.0.113.21", private_ip = "10.20.0.21" },
      ])
    }
  }
}

override_resource {
  target          = exoscale_nlb.this
  override_during = plan
  values = {
    id         = "00000000-0000-0000-0000-000000000001"
    ip_address = "203.0.113.10"
  }
}

override_resource {
  target          = exoscale_compute_instance.jumphost
  override_during = plan
  values          = { public_ip_address = "203.0.113.11" }
}

override_resource {
  target          = time_static.created
  override_during = plan
  values          = { rfc3339 = "2026-10-06T12:34:56Z" }
}

variables {
  exoscale_api_key        = "EXODUMMYKEY"
  exoscale_api_secret     = "DUMMY-SECRET"
  region                  = "de-fra-1"
  admin_cidrs             = ["198.51.100.0/24"]
  api_cidrs               = ["198.51.100.0/24"]
  root_password_hash      = "$6$DUMMYSALT$ROOTDUMMYHASHROOTDUMMYHASHROOTDUMMYHASHROOTDUMMYHASHROOTDUMMYHASH0"
  node_user_password_hash = "$6$DUMMYSALT$NODEDUMMYHASHNODEDUMMYHASHNODEDUMMYHASHNODEDUMMYHASHNODEDUMMYHASH0"
  ssh_authorized_keys     = ["ssh-ed25519 AAAADUMMY test"]
  cluster_name            = "out-exo"
  control_plane_count     = 3
  appco_username          = "DUMMY-APPCO-USER"
  appco_password          = "DUMMY-APPCO-PASSWORD"
  suse_registry_username  = "DUMMY-REGCODE"
  suse_registry_password  = "DUMMY-REGISTRY-PASSWORD"
  nvidia_api_key          = "DUMMY-NVIDIA-API-KEY"
  control_plane_public_ip = true
  gpu_pools               = { gpu = { instance_type = "gpu3.small", count = 2, public_ip = true } }
  # A template ID skips the name lookup, whose id the mock cannot fill.
  jumphost_image = "00000000-0000-0000-0000-00000000000a"
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
    condition     = output.provider == "exoscale" && output.cluster_name == "out-exo" && output.region == "de-fra-1"
    error_message = "provider, cluster_name or region is wrong."
  }

  assert {
    condition     = output.api_vip == "203.0.113.10" && output.api_host == "rke2-203.0.113.10.sslip.io"
    error_message = "api_vip and api_host must come from the NLB address."
  }

  assert {
    condition     = output.jumphost.private_ip == "10.20.0.5" && output.jumphost.ssh_user == "suse"
    error_message = "jumphost must carry its static lease and ssh_user."
  }

  assert {
    condition     = alltrue([for k in ["vpc_cidr", "subnet_cidrs"] : contains(keys(output.network), k)])
    error_message = "network must be { vpc_cidr, subnet_cidrs }."
  }
}

run "bootstrap_pass" {
  command = plan

  assert {
    condition     = exoscale_instance_pool.control_plane[0].size == 1
    error_message = "Pass 1 must run a single control plane member."
  }

  assert {
    # files[1] is /var/lib/elemental/runtime.env, a base64 data URL.
    condition     = strcontains(base64decode(split(",", jsondecode(exoscale_instance_pool.control_plane[0].user_data).storage.files[1].contents.source)[1]), "IS_INIT_NODE=true")
    error_message = "Pass 1 must render the init configuration."
  }

  assert {
    condition     = length(terraform_data.cp_init_ready) == 1
    error_message = "Pass 1 must wait for the first member."
  }

  assert {
    condition     = length(exoscale_security_group_rule.image_import) == 1
    error_message = "Port 80 must be open for the template import on pass 1."
  }
}

run "scale_pass" {
  command = plan

  variables {
    cp_initialized         = true
    image_import_port_open = false
  }

  assert {
    condition     = exoscale_instance_pool.control_plane[0].size == 3
    error_message = "Pass 2 must scale the pool to control_plane_count."
  }

  assert {
    condition     = !strcontains(base64decode(split(",", jsondecode(exoscale_instance_pool.control_plane[0].user_data).storage.files[1].contents.source)[1]), "IS_INIT_NODE")
    error_message = "Pass 2 must render the join configuration."
  }

  assert {
    condition     = length(terraform_data.cp_init_ready) == 0 && length(exoscale_security_group_rule.image_import) == 0 && length(data.http.image_md5) == 0
    error_message = "Pass 2 must close port 80 and skip the init wait and the MD5 read."
  }
}

run "security_groups" {
  command = plan

  assert {
    condition = alltrue([
      contains(keys(exoscale_security_group_rule.control_plane), "api-198.51.100.0/24"),
      contains(keys(exoscale_security_group_rule.control_plane), "healthcheck-9345"),
      contains(keys(exoscale_security_group_rule.control_plane), "healthcheck-8080"),
      contains(keys(exoscale_security_group_rule.control_plane), "nodes-9345-agent"),
    ])
    error_message = "Control plane rules must cover api_cidrs, the NLB healthchecks and node joins."
  }

  assert {
    condition     = exoscale_security_group_rule.control_plane["healthcheck-9345"].public_security_group == "public-nlb-healthcheck-sources"
    error_message = "Healthchecks must come from the managed public-nlb-healthcheck-sources group."
  }

  assert {
    condition     = length([for k, r in exoscale_security_group_rule.control_plane : k if r.start_port == 22]) == 0
    error_message = "No node may accept SSH from outside: the jumphost is the only entry."
  }
}

run "labels" {
  command = plan

  assert {
    condition = alltrue([
      for k in ["elemental-cluster", "elemental-managed-by", "elemental-module", "elemental-created"] :
      contains(keys(exoscale_instance_pool.control_plane[0].labels), k)
    ]) && exoscale_instance_pool.control_plane[0].labels["elemental-created"] == "20261006-123456"
    error_message = "The control plane pool must carry the managed labels."
  }
}

run "type_not_available" {
  command = plan

  variables {
    gpu_pools = { gpu = { instance_type = "gpurtx6000pro.small", count = 1, public_ip = true } }
  }

  expect_failures = [terraform_data.api_check]
}

run "gpu_quota_short" {
  command = plan

  variables {
    gpu_pools = { gpu = { instance_type = "gpu3.small", count = 3, public_ip = true } }
  }

  expect_failures = [terraform_data.api_check]
}

run "worker_on_gpu_type" {
  command = plan

  variables {
    gpu_pools    = {}
    worker_pools = { cpu = { instance_type = "gpu3.small", count = 1, public_ip = true } }
  }

  expect_failures = [terraform_data.api_check]
}

run "zones_at_most_one" {
  command = plan

  variables {
    zones = ["a", "b"]
  }

  expect_failures = [exoscale_private_network.this]
}

run "pool_fields_unsupported" {
  command = plan

  variables {
    gpu_pools = { gpu = { instance_type = "gpu3.small", count = 1, public_ip = true, placement = "spread" } }
  }

  expect_failures = [exoscale_private_network.this]
}

run "control_plane_count_anti_affinity" {
  command = plan

  variables {
    control_plane_count = 9
  }

  expect_failures = [exoscale_private_network.this]
}

# Every node has a public IPv4: false is rejected, not ignored.
run "control_plane_public_ip_false" {
  command = plan

  variables {
    control_plane_public_ip = false
  }

  expect_failures = [exoscale_private_network.this]
}

run "pool_public_ip_default" {
  command = plan

  variables {
    worker_pools = { cpu = { instance_type = "standard.medium", count = 1 } }
  }

  expect_failures = [exoscale_private_network.this]
}

run "retained_templates" {
  command = plan

  variables {
    retained_template_ids = ["tmpl-a", "tmpl-b"]
  }

  assert {
    condition     = toset(keys(exoscale_template.retained)) == toset(["tmpl-a", "tmpl-b"]) && length(exoscale_template.ai_factory) == 1
    error_message = "Each retained template id is held next to the current template."
  }
}
