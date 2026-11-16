# Asserts the nodes: hostnames, placement over availability and fault domains,
# user_data, NLB backends, quota, the jumphost lifecycle and the node outputs.
# OCI mocked; no cloud calls.

mock_provider "oci" {
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
  target          = data.oci_identity_availability_domains.this
  override_during = plan
  values = {
    availability_domains = [
      { compartment_id = "ocid1.tenancy.oc1..dummy", id = "ocid1.availabilitydomain.oc1..ad1", name = "KiWy:EU-FRANKFURT-1-AD-1" },
      { compartment_id = "ocid1.tenancy.oc1..dummy", id = "ocid1.availabilitydomain.oc1..ad2", name = "KiWy:EU-FRANKFURT-1-AD-2" },
      { compartment_id = "ocid1.tenancy.oc1..dummy", id = "ocid1.availabilitydomain.oc1..ad3", name = "KiWy:EU-FRANKFURT-1-AD-3" },
    ]
  }
}

override_data {
  target          = data.oci_core_shapes.zone
  override_during = plan
  values = {
    shapes = [
      for n in ["VM.Standard.E5.Flex", "VM.GPU.A10.1", "VM.GPU.A10.2"] : {
        name                              = n
        baseline_ocpu_utilizations        = []
        billing_type                      = null
        bs_nvme_attachments_config        = []
        gpu_description                   = null
        gpus                              = null
        is_billed_for_stopped_instance    = null
        is_cnic                           = null
        is_flexible                       = null
        is_live_migration_supported       = null
        is_subcore                        = null
        local_disk_description            = null
        local_disks                       = null
        local_disks_total_size_in_gbs     = null
        max_vnic_attachment_options       = []
        max_vnic_attachments              = null
        memory_in_gbs                     = null
        memory_options                    = []
        min_total_baseline_ocpus_required = null
        network_ports                     = null
        networking_bandwidth_in_gbps      = null
        networking_bandwidth_options      = []
        ocpu_options                      = []
        ocpus                             = null
        platform_config_options           = []
        platform_names                    = []
        processor_description             = null
        quota_names                       = []
        rdma_bandwidth_in_gbps            = null
        rdma_ports                        = null
        recommended_alternatives          = []
        resize_compatible_shapes          = []
        supported_resource_management     = []
      }
    ]
  }
}

override_data {
  target          = data.oci_core_instances.existing
  override_during = plan
  values          = { instances = [] }
}

override_data {
  target          = data.oci_network_load_balancer_network_load_balancers.existing
  override_during = plan
  values          = { network_load_balancer_collection = [] }
}

override_data {
  target          = data.oci_core_public_ips.existing
  override_during = plan
  values          = { public_ips = [] }
}

override_data {
  target          = data.oci_limits_resource_availability.this
  override_during = plan
  values          = { available = "1000" }
}

override_data {
  target          = data.oci_core_compute_global_image_capability_schemas.this
  override_during = plan
  values = {
    compute_global_image_capability_schemas = [
      { compartment_id = null, current_version_name = "1.0.0", defined_tags = {}, display_name = "Global", freeform_tags = {}, id = "ocid1.computeglobalimagecapabilityschema.oc1..dummy", time_created = null },
    ]
  }
}

override_data {
  target          = data.oci_objectstorage_namespace.this
  override_during = plan
  values          = { namespace = "dummyns" }
}

override_resource {
  target          = oci_core_public_ip.nlb
  override_during = plan
  values = {
    id         = "ocid1.publicip.oc1..nlb"
    ip_address = "203.0.113.10"
  }
}

override_resource {
  target          = oci_core_nat_gateway.this
  override_during = plan
  values          = { nat_ip = "203.0.113.20" }
}

override_resource {
  target          = oci_core_instance.jumphost
  override_during = plan
  values = {
    public_ip  = "203.0.113.11"
    private_ip = "10.20.0.5"
  }
}

override_resource {
  target          = oci_core_instance.node
  override_during = plan
  values = {
    id         = "ocid1.instance.oc1..node"
    private_ip = "10.20.8.10"
  }
}

override_resource {
  target          = time_static.created
  override_during = plan
  values          = { rfc3339 = "2026-11-13T12:34:56Z" }
}

variables {
  oci_tenancy_ocid        = "ocid1.tenancy.oc1..dummy"
  oci_compartment_ocid    = "ocid1.compartment.oc1..dummy"
  region                  = "eu-frankfurt-1"
  admin_cidrs             = ["198.51.100.0/24"]
  api_cidrs               = ["198.51.100.0/24"]
  root_password_hash      = "$6$DUMMYSALT$ROOTDUMMYHASHROOTDUMMYHASHROOTDUMMYHASHROOTDUMMYHASHROOTDUMMYHASH0"
  node_user_password_hash = "$6$DUMMYSALT$NODEDUMMYHASHNODEDUMMYHASHNODEDUMMYHASHNODEDUMMYHASHNODEDUMMYHASH0"
  ssh_authorized_keys     = ["ssh-ed25519 AAAADUMMY test"]
  cluster_name            = "nodes-oci"
  deploy_nodes            = true
  appco_username          = "DUMMY-APPCO-USER"
  appco_password          = "DUMMY-APPCO-PASSWORD"
  suse_registry_username  = "DUMMY-REGCODE"
  suse_registry_password  = "DUMMY-REGISTRY-PASSWORD"
  nvidia_api_key          = "DUMMY-NVIDIA-API-KEY"
  gpu_pools               = { gpu = { instance_type = "VM.GPU.A10.1", count = 2 } }
  worker_pools            = { wrk = { instance_type = "VM.Standard.E5.Flex:8x64", count = 1, disk_size_gb = 300 } }
  control_plane_count     = 3
  # An OCID skips the platform image lookup.
  jumphost_image = "ocid1.image.oc1..jumphost"
}

run "hostnames_and_roles" {
  command = plan

  assert {
    condition = join(",", sort(keys(oci_core_instance.node))) == join(",", [
      "nodes-oci-cp-01", "nodes-oci-cp-02", "nodes-oci-cp-03",
      "nodes-oci-gpu-01", "nodes-oci-gpu-02", "nodes-oci-wrk-01",
    ])
    error_message = "Nodes must be named <cluster>-<pool>-NN, control planes cp."
  }

  assert {
    condition = alltrue([
      for h, n in output.nodes : n.init == (h == "nodes-oci-cp-01")
    ]) && output.nodes["nodes-oci-gpu-01"].role == "gpu" && output.nodes["nodes-oci-wrk-01"].role == "worker" && output.nodes["nodes-oci-cp-02"].role == "control_plane"
    error_message = "Only the first control plane is init; pools carry their role."
  }

  assert {
    condition = alltrue([
      for h, n in output.nodes :
      n.public_ip == null && n.ssh_user == "suse" && n.private_ip == "10.20.8.10" && n.id == "ocid1.instance.oc1..node" && n.zone == "ad-1"
    ]) && output.nodes["nodes-oci-gpu-01"].instance_type == "VM.GPU.A10.1" && output.nodes["nodes-oci-wrk-01"].instance_type == "VM.Standard.E5.Flex:8x64"
    error_message = "nodes output fields are wrong."
  }
}

run "instance_shape" {
  command = plan

  assert {
    condition = (
      oci_core_instance.node["nodes-oci-cp-01"].shape == "VM.Standard.E5.Flex" &&
      oci_core_instance.node["nodes-oci-cp-01"].shape_config[0].ocpus == 4 &&
      oci_core_instance.node["nodes-oci-cp-01"].shape_config[0].memory_in_gbs == 32 &&
      oci_core_instance.node["nodes-oci-cp-01"].source_details[0].boot_volume_size_in_gbs == "100" &&
      oci_core_instance.node["nodes-oci-wrk-01"].source_details[0].boot_volume_size_in_gbs == "300" &&
      oci_core_instance.node["nodes-oci-gpu-01"].shape == "VM.GPU.A10.1" &&
      length(oci_core_instance.node["nodes-oci-gpu-01"].shape_config) == 0 &&
      oci_core_instance.node["nodes-oci-gpu-01"].source_details[0].boot_volume_size_in_gbs == "200"
    )
    error_message = "Flex shapes get a size, fixed shapes none; disks follow the defaults and pool overrides."
  }

  assert {
    condition = alltrue([
      for h, i in oci_core_instance.node :
      !i.preserve_boot_volume && i.instance_options[0].are_legacy_imds_endpoints_disabled &&
      !i.create_vnic_details[0].assign_public_ip && length(i.create_vnic_details[0].nsg_ids) == 1
    ])
    error_message = "Nodes are private, disable legacy IMDS and delete their boot volume."
  }
}

run "fault_domain_spread" {
  command = plan

  assert {
    condition = (
      oci_core_instance.node["nodes-oci-cp-01"].fault_domain == "FAULT-DOMAIN-1" &&
      oci_core_instance.node["nodes-oci-cp-02"].fault_domain == "FAULT-DOMAIN-2" &&
      oci_core_instance.node["nodes-oci-cp-03"].fault_domain == "FAULT-DOMAIN-3" &&
      oci_core_instance.node["nodes-oci-gpu-01"].fault_domain == "FAULT-DOMAIN-1" &&
      oci_core_instance.node["nodes-oci-gpu-02"].fault_domain == "FAULT-DOMAIN-2"
    )
    error_message = "Nodes of a group must spread over the fault domains of their availability domain."
  }
}

run "zones_spread" {
  command = plan

  variables {
    zones                  = ["ad-1", "ad-2"]
    worker_pools           = { wrk = { instance_type = "VM.Standard.E5.Flex:8x64", count = 2 }, pin = { instance_type = "VM.Standard.E5.Flex:2x16", count = 2, zone = "ad-2" } }
    jumphost_instance_type = "VM.Standard.E5.Flex:2x16"
  }

  assert {
    condition = (
      output.nodes["nodes-oci-cp-01"].zone == "ad-1" && output.nodes["nodes-oci-cp-02"].zone == "ad-2" && output.nodes["nodes-oci-cp-03"].zone == "ad-1" &&
      oci_core_instance.node["nodes-oci-cp-03"].fault_domain == "FAULT-DOMAIN-2" &&
      oci_core_instance.node["nodes-oci-cp-03"].availability_domain == "KiWy:EU-FRANKFURT-1-AD-1" &&
      output.nodes["nodes-oci-wrk-01"].zone == "ad-1" && output.nodes["nodes-oci-wrk-02"].zone == "ad-2" &&
      output.nodes["nodes-oci-pin-01"].zone == "ad-2" && output.nodes["nodes-oci-pin-02"].zone == "ad-2" &&
      oci_core_instance.node["nodes-oci-pin-02"].fault_domain == "FAULT-DOMAIN-2"
    )
    error_message = "Control planes and pools without zone go round-robin over the zones; a pool zone pins its nodes."
  }
}

run "pool_zone_outside_zones" {
  command = plan

  variables {
    worker_pools = { wrk = { instance_type = "VM.Standard.E5.Flex:8x64", count = 1, zone = "ad-2" } }
  }

  expect_failures = [terraform_data.input_checks]
}

run "user_data" {
  command = plan

  assert {
    condition = alltrue([
      for h, i in oci_core_instance.node :
      contains(keys(i.metadata), "user_data") && length(i.metadata) == 2 && length(i.metadata["user_data"]) < 31000
    ])
    error_message = "Each node carries its Ignition as base64 user_data under the metadata budget."
  }
}

run "user_data_over_budget" {
  command = plan

  variables {
    ssh_authorized_keys = [for i in range(45) : "ssh-rsa ${join("", [for j in range(70) : format("%010d", i * 1000 + j * 7919 + 1234567)])} test"]
  }

  expect_failures = [oci_core_instance.node]
}

run "nlb_backends" {
  command = plan

  assert {
    condition = (
      length(oci_network_load_balancer_backend.this) == 12 &&
      alltrue([for k, b in oci_network_load_balancer_backend.this : contains(["6443", "9345", "80", "443"], tostring(b.port))]) &&
      alltrue([for k, b in oci_network_load_balancer_backend.this : b.target_id == "ocid1.instance.oc1..node"]) &&
      length([for k, b in oci_network_load_balancer_backend.this : k if startswith(k, "kube_api/")]) == 3 &&
      length([for k, b in oci_network_load_balancer_backend.this : k if startswith(k, "supervisor/") && strcontains(k, "-cp-")]) == 3 &&
      length([for k, b in oci_network_load_balancer_backend.this : k if strcontains(k, "-gpu-") || strcontains(k, "-wrk-")]) == 0
    )
    error_message = "Every listener has the control planes as backends and no agents."
  }

  assert {
    condition = (
      !oci_network_load_balancer_backend_set.this["kube_api"].is_preserve_source &&
      !oci_network_load_balancer_backend_set.this["supervisor"].is_preserve_source &&
      !oci_network_load_balancer_backend_set.this["http"].is_preserve_source &&
      !oci_network_load_balancer_backend_set.this["https"].is_preserve_source
    )
    error_message = "No backend set preserves the client address (hairpin through the NAT gateway)."
  }
}

run "nlb_backend_ports_follow_ingress" {
  command = plan

  variables {
    ingress_controller = "none"
  }

  assert {
    condition     = length(oci_network_load_balancer_backend.this) == 6
    error_message = "Without an ingress controller only the API and supervisor have backends."
  }
}

run "api_client_rules" {
  command = plan

  assert {
    condition = alltrue([
      contains(keys(oci_network_load_balancer_backend_set.this), "kube_api"),
      contains(keys(oci_network_load_balancer_backend_set.this), "supervisor"),
      contains(keys(oci_network_load_balancer_backend_set.this), "https"),
      !contains(keys(oci_core_network_security_group_security_rule.this), "control_plane-client-6443-198.51.100.0/24"),
      !contains(keys(oci_core_network_security_group_security_rule.this), "control_plane-client-9345-nat"),
      contains(keys(oci_core_network_security_group_security_rule.this), "nlb-client-6443-198.51.100.0/24"),
      contains(keys(oci_core_network_security_group_security_rule.this), "nlb-client-443-nat"),
      !contains(keys(oci_core_network_security_group_security_rule.this), "control_plane-client-443-0.0.0.0/0"),
      contains(keys(oci_core_network_security_group_security_rule.this), "nlb-client-443-0.0.0.0/0"),
      contains(keys(oci_core_network_security_group_security_rule.this), "control_plane-nlb-6443"),
      contains(keys(oci_core_network_security_group_security_rule.this), "control_plane-nlb-9345"),
      contains(keys(oci_core_network_security_group_security_rule.this), "control_plane-nlb-443"),
    ])
    error_message = "api_cidrs and ingress_cidrs are enforced on the NLB group; the control plane group admits only the NLB subnet on listener ports."
  }
}

run "labels" {
  command = plan

  assert {
    condition = (
      oci_core_instance.node["nodes-oci-gpu-01"].freeform_tags["elemental-role"] == "gpu" &&
      oci_core_instance.node["nodes-oci-gpu-01"].freeform_tags["elemental-pool"] == "gpu" &&
      oci_core_instance.node["nodes-oci-cp-01"].freeform_tags["elemental-role"] == "control_plane" &&
      oci_core_instance.node["nodes-oci-wrk-01"].freeform_tags["elemental-role"] == "worker" &&
      contains(keys(oci_core_instance.node["nodes-oci-wrk-01"].freeform_tags), "elemental-build") &&
      oci_core_instance.node["nodes-oci-wrk-01"].freeform_tags["elemental-created"] == "20261113-123456"
    )
    error_message = "Nodes carry role, pool, build and the managed labels."
  }
}

run "image_id_keeps_bastion" {
  command = plan

  variables {
    image_id = "ocid1.image.oc1..pinned"
  }

  assert {
    condition = alltrue([
      length(oci_core_image.ai_factory) == 0,
      length(oci_core_instance.jumphost) == 1,
      length(oci_objectstorage_bucket.build) == 0,
      length(terraform_data.image_ready) == 0,
      length(oci_core_instance.node) == 6,
    ])
    error_message = "With image_id and nodes the jumphost stays as the bastion and nothing is built."
  }

  assert {
    condition = alltrue([
      for h, i in oci_core_instance.node : i.source_details[0].source_id == "ocid1.image.oc1..pinned"
    ]) && output.jumphost.public_ip == "203.0.113.11" && output.build_status == null
    error_message = "Nodes boot the pinned image and the outputs keep the jumphost."
  }

  assert {
    condition     = !strcontains(oci_core_instance.jumphost[0].metadata["user_data"], "image-factory") && length(oci_core_instance.jumphost[0].metadata["user_data"]) < 2000
    error_message = "The bastion jumphost builds nothing: its user_data carries no factory."
  }
}

run "no_nodes_no_bastion_with_image_id" {
  command = plan

  variables {
    deploy_nodes = false
    image_id     = "ocid1.image.oc1..pinned"
  }

  assert {
    condition     = length(oci_core_instance.jumphost) == 0 && length(oci_core_instance.node) == 0 && length(oci_network_load_balancer_backend.this) == 0
    error_message = "Without nodes and with image_id nothing runs but the network and the load balancer."
  }
}

run "next_steps_with_nodes" {
  command = plan

  variables {
    image_id = "ocid1.image.oc1..pinned"
  }

  assert {
    condition     = strcontains(output.next_steps, "kubeconfig.sh") && strcontains(output.next_steps, "ssh.sh")
    error_message = "next_steps must hint at the kubeconfig and ssh helpers once nodes exist."
  }
}

run "gpu_quota_short" {
  command = plan

  override_data {
    target          = data.oci_limits_resource_availability.this
    override_during = plan
    values          = { available = "1" }
  }

  expect_failures = [terraform_data.limits_check]
}

run "pool_shape_not_offered_in_its_zone" {
  command = plan

  variables {
    gpu_pools = { gpu = { instance_type = "VM.GPU.A10.2", count = 1 } }
  }

  override_data {
    target          = data.oci_core_shapes.zone
    override_during = plan
    values = {
      shapes = [{
        name                           = "VM.Standard.E5.Flex", baseline_ocpu_utilizations = [], billing_type = null, bs_nvme_attachments_config = [], gpu_description = null, gpus = null,
        is_billed_for_stopped_instance = null, is_cnic = null, is_flexible = null, is_live_migration_supported = null, is_subcore = null,
        local_disk_description         = null, local_disks = null, local_disks_total_size_in_gbs = null, max_vnic_attachment_options = [], max_vnic_attachments = null,
        memory_in_gbs                  = null, memory_options = [], min_total_baseline_ocpus_required = null, network_ports = null, networking_bandwidth_in_gbps = null,
        networking_bandwidth_options   = [], ocpu_options = [], ocpus = null, platform_config_options = [], platform_names = [], processor_description = null,
        quota_names                    = [], rdma_bandwidth_in_gbps = null, rdma_ports = null, recommended_alternatives = [], resize_compatible_shapes = [], supported_resource_management = [],
      }]
    }
  }

  expect_failures = [terraform_data.limits_check]
}
