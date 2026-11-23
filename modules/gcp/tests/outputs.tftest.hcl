# Asserts the common output set (docs/conventions.md#outputs), node placement and settings,
# the image chain (target disk, snapshot, image), labels, image_id and the plan-time input
# checks. Google provider mocked; no cloud calls. Addresses of instances are unknown at plan.

mock_provider "google" {
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
  target          = data.google_client_config.this
  override_during = plan
  values = {
    access_token   = "dummy-token"
    default_labels = {}
    id             = "projects/dummy-project/regions/europe-west4/zones/europe-west4-a"
    project        = "dummy-project"
    region         = "europe-west4"
    zone           = "europe-west4-a"
  }
}

override_data {
  target          = data.google_compute_zones.region
  override_during = plan
  values = {
    id    = "projects/dummy-project/regions/europe-west4"
    names = ["europe-west4-a", "europe-west4-b", "europe-west4-c"]
  }
}

# One entry for every type and zone: 4 vCPUs, no accelerator.
override_data {
  target          = data.google_compute_machine_types.this
  override_during = plan
  values = {
    id = "dummy"
    machine_types = [{
      accelerators                     = []
      architecture                     = "X86_64"
      deprecated                       = []
      description                      = "dummy"
      guest_cpus                       = 4
      is_shared_cpus                   = false
      maximum_persistent_disks         = 128
      maximum_persistent_disks_size_gb = 263168
      memory_mb                        = 16384
      name                             = "dummy"
      self_link                        = "https://www.googleapis.com/compute/v1/projects/dummy-project/zones/europe-west4-a/machineTypes/dummy"
    }]
  }
}

override_data {
  target          = data.http.region
  override_during = plan
  values = {
    status_code = 200
    response_body = jsonencode({ quotas = [
      { metric = "CPUS", limit = 1000, usage = 0 },
      { metric = "N2_CPUS", limit = 1000, usage = 0 },
      { metric = "SSD_TOTAL_GB", limit = 100000, usage = 0 },
      { metric = "STATIC_ADDRESSES", limit = 8, usage = 0 },
      { metric = "IN_USE_ADDRESSES", limit = 8, usage = 0 },
    ] })
  }
}

override_data {
  target          = data.http.project
  override_during = plan
  values = {
    status_code = 200
    response_body = jsonencode({ quotas = [
      { metric = "GPUS_ALL_REGIONS", limit = 100, usage = 0 },
      { metric = "CPUS_ALL_REGIONS", limit = 10000, usage = 0 },
    ] })
  }
}

override_data {
  target          = data.http.existing_instances
  override_during = plan
  values = {
    status_code   = 200
    response_body = "{}"
  }
}

override_data {
  target          = data.http.existing_addresses
  override_during = plan
  values = {
    status_code   = 200
    response_body = "{}"
  }
}

override_resource {
  target          = google_compute_address.external_lb
  override_during = plan
  values = {
    address = "203.0.113.10"
  }
}

override_resource {
  target          = google_compute_address.internal_lb
  override_during = plan
  values = {
    address = "10.20.0.100"
  }
}

override_resource {
  target          = google_compute_address.nat
  override_during = plan
  values = {
    address   = "203.0.113.20"
    self_link = "https://www.googleapis.com/compute/v1/projects/dummy-project/regions/europe-west4/addresses/nat"
  }
}

override_resource {
  target          = google_compute_image.ai_factory
  override_during = plan
  values = {
    self_link = "https://www.googleapis.com/compute/v1/projects/dummy-project/global/images/gcp-test-built"
  }
}

override_resource {
  target          = random_password.token
  override_during = plan
  values          = { result = "dummytokendummytokendummytoken00" }
}

override_resource {
  target          = module.config.random_password.rancher_bootstrap
  override_during = plan
  values          = { result = "dummybootstrapdummybootstrap0000" }
}

override_resource {
  target          = time_static.created
  override_during = plan
  values          = { rfc3339 = "2026-11-13T12:34:56Z" }
}

variables {
  gcp_project             = "dummy-project"
  region                  = "europe-west4"
  admin_cidrs             = ["198.51.100.0/24"]
  api_cidrs               = ["198.51.100.0/24"]
  root_password_hash      = "$6$DUMMYSALT$ROOTDUMMYHASHROOTDUMMYHASHROOTDUMMYHASHROOTDUMMYHASHROOTDUMMYHASH0"
  node_user_password_hash = "$6$DUMMYSALT$NODEDUMMYHASHNODEDUMMYHASHNODEDUMMYHASHNODEDUMMYHASHNODEDUMMYHASH0"
  ssh_authorized_keys     = ["ssh-ed25519 AAAADUMMY test"]
  cluster_name            = "gcp-test"
  deploy_nodes            = true
  appco_username          = "DUMMY-APPCO-USER"
  appco_password          = "DUMMY-APPCO-PASSWORD"
  suse_registry_username  = "DUMMY-REGCODE"
  suse_registry_password  = "DUMMY-REGISTRY-PASSWORD"
  nvidia_api_key          = "DUMMY-NVIDIA-API-KEY"
  gpu_pools               = { gpu = { instance_type = "g2-standard-4", count = 2 } }
  worker_pools            = { wrk = { instance_type = "n2-standard-8", count = 1, disk_size_gb = 300 } }
  control_plane_count     = 3
  zones                   = ["europe-west4-a", "europe-west4-b", "europe-west4-c"]
}

run "output_set" {
  command = plan

  assert {
    condition = alltrue([
      for k in [
        "provider", "cluster_name", "region", "kubernetes_api_endpoint", "api_host", "api_vip", "ingress_endpoint",
        "rancher_url", "rancher_hostname", "rancher_bootstrap_password", "jumphost", "nodes", "image", "egress_ips",
        "network", "build_status", "security", "security_credentials", "observability", "observability_credentials",
        "next_steps", "provider_details",
        ] : contains(keys(nonsensitive({ for k, v in {
          provider                   = output.provider, cluster_name = output.cluster_name, region = output.region,
          kubernetes_api_endpoint    = output.kubernetes_api_endpoint, api_host = output.api_host, api_vip = output.api_vip,
          ingress_endpoint           = output.ingress_endpoint, rancher_url = output.rancher_url, rancher_hostname = output.rancher_hostname,
          rancher_bootstrap_password = nonsensitive(output.rancher_bootstrap_password), jumphost = output.jumphost, nodes = output.nodes,
          image                      = output.image, egress_ips = output.egress_ips, network = output.network, build_status = output.build_status,
          security                   = output.security, security_credentials = nonsensitive(output.security_credentials),
          observability              = output.observability, observability_credentials = nonsensitive(output.observability_credentials),
          next_steps                 = output.next_steps, provider_details = output.provider_details,
      } : k => "x" })), k)
    ])
    error_message = "Every output of docs/conventions.md#outputs must exist."
  }

  assert {
    condition     = output.provider == "gcp" && output.region == "europe-west4" && output.cluster_name == "gcp-test"
    error_message = "provider, region and cluster_name are wrong."
  }

  assert {
    condition = (
      output.api_vip == "10.20.0.100" &&
      output.api_host == "rke2-203.0.113.10.sslip.io" &&
      output.kubernetes_api_endpoint == "https://rke2-203.0.113.10.sslip.io:6443" &&
      output.rancher_hostname == "rancher-203.0.113.10.sslip.io" &&
      output.ingress_endpoint == "https://203.0.113.10"
    )
    error_message = "api_vip is the internal address; api_host, Rancher and the ingress use the external one."
  }

  assert {
    condition = (
      join(",", output.egress_ips) == "203.0.113.20" &&
      output.network.vpc_cidr == "10.20.0.0/20" && output.network.subnet_cidrs == ["10.20.0.0/20"]
    )
    error_message = "egress_ips is the reserved NAT address; network has one subnet."
  }

  assert {
    condition     = terraform_data.build_access[0].input.build_status.method == "guest-attributes" && output.build_status == null
    error_message = "build_status is null once the image exists; the build host is in state while it is built."
  }

  assert {
    condition     = output.security == null && output.observability == null && output.image.ids["europe-west4"] == "https://www.googleapis.com/compute/v1/projects/dummy-project/global/images/gcp-test-built"
    error_message = "security and observability are null without their components."
  }

  assert {
    condition     = output.provider_details.project == "dummy-project" && output.provider_details.load_balancers.internal_address == "10.20.0.100"
    error_message = "provider_details must carry the project and the load balancer addresses."
  }
}

run "nodes_output" {
  command = plan

  assert {
    condition = join(",", sort(keys(output.nodes))) == join(",", [
      "gcp-test-cp-01", "gcp-test-cp-02", "gcp-test-cp-03",
      "gcp-test-gpu-01", "gcp-test-gpu-02", "gcp-test-wrk-01",
    ])
    error_message = "Nodes must be named <cluster>-<pool>-NN, control planes cp."
  }

  assert {
    condition = alltrue([for h, n in output.nodes : n.init == (h == "gcp-test-cp-01")]) && (
      output.nodes["gcp-test-gpu-01"].role == "gpu" && output.nodes["gcp-test-wrk-01"].role == "worker" && output.nodes["gcp-test-cp-02"].role == "control_plane"
    )
    error_message = "Only the first control plane is init; pools carry their role."
  }

  assert {
    condition = alltrue([for h, n in output.nodes : n.ssh_user == "suse"]) && (
      output.nodes["gcp-test-gpu-01"].instance_type == "g2-standard-4" && output.nodes["gcp-test-wrk-01"].instance_type == "n2-standard-8"
    )
    error_message = "nodes output fields are wrong."
  }

  assert {
    condition = (
      output.nodes["gcp-test-cp-01"].zone == "europe-west4-a" && output.nodes["gcp-test-cp-02"].zone == "europe-west4-b" &&
      output.nodes["gcp-test-cp-03"].zone == "europe-west4-c" && output.nodes["gcp-test-gpu-01"].zone == "europe-west4-a" &&
      output.nodes["gcp-test-gpu-02"].zone == "europe-west4-b" && output.nodes["gcp-test-wrk-01"].zone == "europe-west4-a"
    )
    error_message = "Nodes go round-robin over the zones, per group."
  }
}

run "instance_settings" {
  command = plan

  assert {
    condition = (
      google_compute_instance.control_plane["gcp-test-cp-01"].machine_type == "n2-standard-4" &&
      google_compute_instance.control_plane["gcp-test-cp-01"].boot_disk[0].initialize_params[0].size == 100 &&
      google_compute_instance.agent["gcp-test-wrk-01"].boot_disk[0].initialize_params[0].size == 300 &&
      google_compute_instance.agent["gcp-test-gpu-01"].boot_disk[0].initialize_params[0].size == 200
    )
    error_message = "Disk sizes follow the defaults and the pool overrides."
  }

  assert {
    condition = alltrue([
      for h, i in merge(google_compute_instance.control_plane, google_compute_instance.agent) :
      length(i.service_account) == 0 && i.network_interface[0].nic_type == "GVNIC" && length(i.network_interface[0].access_config) == 0 &&
      join(",", keys(i.metadata)) == "user-data" && i.boot_disk[0].initialize_params[0].type == "pd-balanced"
    ])
    error_message = "Nodes have no service account and no public address, use gVNIC, take only user-data metadata and boot from pd-balanced."
  }

  assert {
    condition     = length(google_compute_firewall.node_clients) == 0
    error_message = "Without public node addresses there is no node-clients rule."
  }

  assert {
    condition     = google_compute_instance.jumphost[0].network_interface[0].nic_type == null
    error_message = "The e2 jumphost keeps the default NIC: its public image may not declare gVNIC."
  }

  assert {
    condition = (
      google_compute_instance.control_plane["gcp-test-cp-01"].tags == toset(["gcp-test-control-plane"]) &&
      google_compute_instance.agent["gcp-test-gpu-01"].tags == toset(["gcp-test-agent"])
    )
    error_message = "Network tags select the firewall rules."
  }

  assert {
    condition = (
      google_compute_instance.agent["gcp-test-gpu-01"].scheduling[0].on_host_maintenance == "TERMINATE" &&
      google_compute_instance.control_plane["gcp-test-cp-01"].scheduling[0].on_host_maintenance == "MIGRATE" &&
      google_compute_instance.agent["gcp-test-gpu-01"].boot_disk[0].interface == "NVME" &&
      google_compute_instance.control_plane["gcp-test-cp-01"].boot_disk[0].interface == null
    )
    error_message = "G2 needs NVMe and TERMINATE; N2 keeps SCSI and migrates."
  }
}

run "disk_type_by_family" {
  command = plan

  variables {
    control_plane_instance_type = "c3-standard-4"
    gpu_pools                   = { gpu = { instance_type = "g4-standard-48", count = 1 } }
    worker_pools                = {}
  }

  assert {
    condition = (
      google_compute_instance.control_plane["gcp-test-cp-01"].boot_disk[0].initialize_params[0].type == "hyperdisk-balanced" &&
      google_compute_instance.control_plane["gcp-test-cp-01"].boot_disk[0].interface == "NVME" &&
      google_compute_instance.agent["gcp-test-gpu-01"].boot_disk[0].initialize_params[0].type == "hyperdisk-balanced" &&
      google_compute_instance.agent["gcp-test-gpu-01"].scheduling[0].on_host_maintenance == "TERMINATE"
    )
    error_message = "C3 and G4 boot from Hyperdisk Balanced over NVMe; G4 terminates on host maintenance."
  }
}

run "public_ip_on_demand" {
  command = plan

  variables {
    control_plane_public_ip = true
    worker_pools            = { wrk = { instance_type = "n2-standard-8", count = 1, public_ip = true } }
  }

  assert {
    condition = (
      length(google_compute_instance.control_plane["gcp-test-cp-01"].network_interface[0].access_config) == 1 &&
      length(google_compute_instance.agent["gcp-test-wrk-01"].network_interface[0].access_config) == 1 &&
      length(google_compute_instance.agent["gcp-test-gpu-01"].network_interface[0].access_config) == 0
    )
    error_message = "control_plane_public_ip and a pool public_ip add an ephemeral address."
  }

  assert {
    condition = (
      length(google_compute_firewall.node_clients) == 1 &&
      toset(flatten([for a in google_compute_firewall.node_clients[0].allow : a.ports])) == toset(["6443", "80", "443"]) &&
      google_compute_firewall.node_clients[0].target_tags == toset(["gcp-test-control-plane"])
    )
    error_message = "Nodes with a public address reach the external load balancer through the node-clients rule."
  }
}

run "labels" {
  command = plan

  variables {
    tags = { team = "ai", cost_center = "42" }
  }

  assert {
    condition = (
      google_compute_instance.control_plane["gcp-test-cp-01"].labels["elemental-cluster"] == "gcp-test" &&
      google_compute_instance.control_plane["gcp-test-cp-01"].labels["elemental-managed-by"] == "terraform" &&
      google_compute_instance.control_plane["gcp-test-cp-01"].labels["elemental-module"] == "ai-factory" &&
      google_compute_instance.control_plane["gcp-test-cp-01"].labels["elemental-created"] == "20261113-123456" &&
      google_compute_instance.control_plane["gcp-test-cp-01"].labels["elemental-role"] == "control_plane" &&
      google_compute_instance.control_plane["gcp-test-cp-01"].labels["elemental-pool"] == "cp" &&
      google_compute_instance.agent["gcp-test-gpu-02"].labels["elemental-role"] == "gpu" &&
      google_compute_instance.agent["gcp-test-gpu-02"].labels["elemental-pool"] == "gpu" &&
      google_compute_instance.control_plane["gcp-test-cp-01"].labels["team"] == "ai"
    )
    error_message = "Instances carry the managed labels, role, pool and var.tags."
  }

  assert {
    condition = (
      google_compute_instance.control_plane["gcp-test-cp-01"].boot_disk[0].initialize_params[0].labels["elemental-pool"] == "cp" &&
      google_compute_instance.jumphost[0].labels["elemental-role"] == "jumphost" &&
      !contains(keys(google_compute_instance.jumphost[0].labels), "elemental-build") &&
      google_compute_disk.image_target[0].labels["elemental-role"] == "image" &&
      contains(keys(google_compute_snapshot.ai_factory[0].labels), "elemental-build") &&
      contains(keys(google_compute_image.ai_factory[0].labels), "elemental-build") &&
      contains(keys(google_compute_disk.image_target[0].labels), "elemental-build") &&
      contains(keys(google_compute_instance.control_plane["gcp-test-cp-01"].labels), "elemental-build") &&
      google_compute_image.ai_factory[0].labels["team"] == "ai"
    )
    error_message = "Disks, jumphost (no build label), snapshot and image are labelled."
  }

  assert {
    condition = (
      google_compute_address.external_lb.labels["elemental-role"] == "lb" &&
      google_compute_address.nat[0].labels["elemental-role"] == "network" &&
      google_compute_forwarding_rule.this["ext-https"].labels["elemental-listener"] == "https" &&
      google_compute_forwarding_rule.this["int-supervisor"].labels["elemental-listener"] == "supervisor"
    )
    error_message = "Addresses and forwarding rules carry role and listener labels."
  }
}

run "tags_must_be_gcp_labels" {
  command = plan

  variables {
    tags = { Team = "AI" }
  }

  expect_failures = [terraform_data.input_checks]
}

run "image_chain" {
  command = plan

  assert {
    condition = (
      google_compute_disk.image_target[0].size == 8 &&
      google_compute_disk.image_target[0].zone == "europe-west4-a" &&
      google_compute_instance.jumphost[0].attached_disk[0].device_name == "image-target" &&
      google_compute_instance.jumphost[0].zone == "europe-west4-a" &&
      google_compute_instance.jumphost[0].metadata["enable-guest-attributes"] == "TRUE" &&
      google_compute_instance.jumphost[0].boot_disk[0].initialize_params[0].image == "projects/opensuse-cloud/global/images/family/opensuse-leap"
    )
    error_message = "The jumphost builds in zones[0] with the blank target disk attached and guest attributes on."
  }

  assert {
    condition = (
      join(",", google_compute_snapshot.ai_factory[0].storage_locations) == "europe-west4" &&
      join(",", google_compute_image.ai_factory[0].storage_locations) == "europe-west4" &&
      toset([for f in google_compute_image.ai_factory[0].guest_os_features : f.type]) == toset(["UEFI_COMPATIBLE", "GVNIC", "VIRTIO_SCSI_MULTIQUEUE"])
    )
    error_message = "The image is regional storage with the UEFI, gVNIC and multiqueue features."
  }

  assert {
    condition     = length(terraform_data.image_ready) == 1 && length(terraform_data.build_access) == 1
    error_message = "The build waits for the jumphost and exposes it in state."
  }

  assert {
    condition     = google_compute_instance.jumphost[0].metadata["ssh-keys"] == "suse:ssh-ed25519 AAAADUMMY test" && output.jumphost.ssh_user == "suse"
    error_message = "The guest agent gets the jumphost user and keys from ssh-keys."
  }
}

run "root_only_jumphost" {
  command = plan

  variables {
    jumphost_username = ""
    image_id          = "projects/dummy-project/global/images/pinned"
  }

  assert {
    condition     = !contains(keys(google_compute_instance.jumphost[0].metadata), "ssh-keys") && output.jumphost.ssh_user == "root"
    error_message = "An empty jumphost_username installs the keys for root from the startup script."
  }

  assert {
    condition     = strcontains(google_compute_instance.jumphost[0].metadata["startup-script"], "/root/.ssh/authorized_keys")
    error_message = "The startup script writes the root authorized_keys."
  }
}

run "image_id_skips_chain" {
  command = plan

  variables {
    image_id     = "projects/dummy-project/global/images/pinned"
    deploy_nodes = false
  }

  assert {
    condition = (
      length(google_compute_image.ai_factory) == 0 && length(google_compute_snapshot.ai_factory) == 0 &&
      length(google_compute_disk.image_target) == 0 && length(google_compute_instance.jumphost) == 0 &&
      length(terraform_data.image_ready) == 0 && output.build_status == null &&
      output.image.ids["europe-west4"] == "projects/dummy-project/global/images/pinned"
    )
    error_message = "image_id replaces the build chain; no jumphost exists without nodes."
  }

  assert {
    condition     = output.jumphost.public_ip == null && length(output.nodes) == 0
    error_message = "No jumphost and no nodes."
  }
}

run "image_id_nodes_use_it" {
  command = plan

  variables {
    image_id = "projects/dummy-project/global/images/pinned"
  }

  assert {
    condition = (
      google_compute_instance.control_plane["gcp-test-cp-01"].boot_disk[0].initialize_params[0].image == "projects/dummy-project/global/images/pinned" &&
      length(google_compute_instance.jumphost) == 1 && !contains(keys(google_compute_instance.jumphost[0].labels), "elemental-build") &&
      !strcontains(google_compute_instance.jumphost[0].metadata["startup-script"], "image-factory")
    )
    error_message = "Nodes boot the pinned image; the jumphost stays as bastion and builds nothing."
  }
}

run "deploy_nodes_false_builds_image_only" {
  command = plan

  variables {
    deploy_nodes = false
  }

  assert {
    condition     = length(output.nodes) == 0 && length(google_compute_image.ai_factory) == 1 && length(google_compute_instance.control_plane) + length(google_compute_instance.agent) == 0
    error_message = "deploy_nodes = false builds the image and creates no nodes."
  }
}

run "image_in_config" {
  command = plan

  assert {
    condition     = strcontains(nonsensitive(module.config.elemental_files["butane.yaml"]), "local-routes.sh 203.0.113.10")
    error_message = "The external address is a boot-time local route on control planes."
  }

  assert {
    condition     = strcontains(nonsensitive(module.config.elemental_files["butane.yaml"]), "local-routes.sh --after-server 10.20.0.100")
    error_message = "The internal address (api_vip) is a local route only after rke2-server is active."
  }

  assert {
    condition     = anytrue([for k, v in nonsensitive(module.config.elemental_files) : strcontains(v, "console=ttyS0,115200n8 ignition.platform.id=gcp") && !strcontains(v, "quiet")])
    error_message = "The kernel command line must set the serial console and ignition.platform.id=gcp without quiet."
  }
}

run "build_id_everywhere" {
  command = plan

  assert {
    condition = (
      length(module.config.build_id) == 12 &&
      google_compute_image.ai_factory[0].labels["elemental-build"] == module.config.build_id &&
      google_compute_snapshot.ai_factory[0].labels["elemental-build"] == module.config.build_id &&
      google_compute_disk.image_target[0].labels["elemental-build"] == module.config.build_id &&
      google_compute_instance.control_plane["gcp-test-cp-01"].labels["elemental-build"] == module.config.build_id &&
      google_compute_image.ai_factory[0].name == "gcp-test-${module.config.build_id}"
    )
    error_message = "The build id labels the image chain and the nodes, and names the image."
  }
}

run "tags_do_not_override_managed" {
  command = plan

  variables {
    tags = { "elemental-role" = "x" }
  }

  expect_failures = [var.tags]
}

run "fractional_g4_rejected" {
  command = plan

  variables {
    gpu_pools = { gpu = { instance_type = "g4-standard-12", count = 1 } }
  }

  expect_failures = [terraform_data.input_checks]
}

run "pool_placement_rejected" {
  command = plan

  variables {
    worker_pools = { wrk = { instance_type = "n2-standard-8", count = 1, placement = "x" } }
  }

  expect_failures = [terraform_data.input_checks]
}

run "pool_bare_metal_rejected" {
  command = plan

  variables {
    worker_pools = { wrk = { instance_type = "n2-standard-8", count = 1, kind = "bare_metal" } }
  }

  expect_failures = [terraform_data.input_checks]
}

run "zone_outside_region" {
  command = plan

  variables {
    zones = ["us-central1-a"]
  }

  expect_failures = [terraform_data.input_checks]
}

run "zone_unknown" {
  command = plan

  variables {
    zones = ["europe-west4-z"]
  }

  expect_failures = [terraform_data.input_checks]
}

run "mtu_range" {
  command = plan

  variables {
    vpc_mtu = 9000
  }

  expect_failures = [terraform_data.input_checks]
}

run "default_zone_is_first_of_region" {
  command = plan

  variables {
    zones = []
  }

  assert {
    condition     = alltrue([for h, n in output.nodes : n.zone == "europe-west4-a"]) && join(",", output.provider_details.zones) == "europe-west4-a"
    error_message = "Empty zones means <region>-a."
  }
}

run "long_cluster_name_rejected" {
  command = plan

  variables {
    cluster_name = "a-very-long-cluster-name-that-overflows"
  }

  expect_failures = [terraform_data.input_checks]
}

run "cluster_name_must_start_with_a_letter" {
  command = plan

  variables {
    cluster_name = "1cluster"
  }

  expect_failures = [terraform_data.input_checks]
}

# Full zone names run up to 25 characters: the common validation accepts them,
# only the region check fails here.
run "long_zone_name_passes_validation" {
  command = plan

  variables {
    zones = ["northamerica-northeast1-a"]
  }

  expect_failures = [terraform_data.input_checks]
}
