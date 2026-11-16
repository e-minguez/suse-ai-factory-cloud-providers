# Asserts the common output set (docs/conventions.md#outputs), the shape
# syntax, the UEFI capability schema, the image_id shortcut, the labels, the
# firewall rules and the plan-time availability checks. OCI mocked; no cloud calls.

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
    ]
  }
}

override_data {
  target          = data.oci_core_shapes.zone
  override_during = plan
  values = {
    shapes = [
      for n in ["VM.Standard.E5.Flex", "VM.GPU.A10.1"] : {
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
  values          = { available = "100" }
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

# Existing network (vpc_id): only read when vpc_id is set.
override_data {
  target          = data.oci_core_vcn.existing
  override_during = plan
  values          = { compartment_id = "ocid1.compartment.oc1..net", cidr_blocks = ["10.30.0.0/16"] }
}

override_data {
  target          = data.oci_core_subnet.public
  override_during = plan
  values = {
    vcn_id              = "ocid1.vcn.oc1..existing", cidr_block = "10.30.0.0/24", route_table_id = "ocid1.routetable.oc1..pub"
    availability_domain = null, prohibit_public_ip_on_vnic = false
  }
}

override_data {
  target          = data.oci_core_subnet.private
  override_during = plan
  values = {
    vcn_id              = "ocid1.vcn.oc1..existing", cidr_block = "10.30.8.0/22", route_table_id = "ocid1.routetable.oc1..priv"
    availability_domain = null, prohibit_public_ip_on_vnic = true
  }
}

override_data {
  target          = data.oci_core_route_tables.existing
  override_during = plan
  values = {
    route_tables = [
      for t in [["pub", "ocid1.internetgateway.oc1..igw"], ["priv", "ocid1.natgateway.oc1..nat"]] : {
        compartment_id = "ocid1.compartment.oc1..net", defined_tags = {}, display_name = t[0], freeform_tags = {}
        id             = "ocid1.routetable.oc1..${t[0]}", state = "AVAILABLE", time_created = null, vcn_id = "ocid1.vcn.oc1..existing"
        route_rules    = [{ cidr_block = null, description = null, destination = "0.0.0.0/0", destination_type = "CIDR_BLOCK", network_entity_id = t[1], route_type = null }]
      }
    ]
  }
}

override_data {
  target          = data.oci_core_nat_gateways.existing
  override_during = plan
  values = {
    nat_gateways = [{
      block_traffic = false, compartment_id = "ocid1.compartment.oc1..net", defined_tags = {}, display_name = "nat", freeform_tags = {}
      id            = "ocid1.natgateway.oc1..nat", nat_ip = "198.51.100.77", public_ip_id = null, route_table_id = null, state = "AVAILABLE"
      time_created  = null, vcn_id = "ocid1.vcn.oc1..existing"
    }]
  }
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
  cluster_name            = "out-oci"
  deploy_nodes            = false
  appco_username          = "DUMMY-APPCO-USER"
  appco_password          = "DUMMY-APPCO-PASSWORD"
  suse_registry_username  = "DUMMY-REGCODE"
  suse_registry_password  = "DUMMY-REGISTRY-PASSWORD"
  nvidia_api_key          = "DUMMY-NVIDIA-API-KEY"
  gpu_pools               = { gpu = { instance_type = "VM.GPU.A10.1", count = 1 } }
  # An OCID skips the platform image lookup.
  jumphost_image = "ocid1.image.oc1..jumphost"
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
      output.security, output.security_credentials, output.observability, output.observability_credentials,
    ]) == 21
    error_message = "A required output is missing."
  }

  assert {
    condition     = output.provider == "oci" && output.cluster_name == "out-oci" && output.region == "eu-frankfurt-1"
    error_message = "provider, cluster_name or region is wrong."
  }

  assert {
    condition     = output.api_vip == "203.0.113.10" && output.api_host == "rke2-203.0.113.10.sslip.io"
    error_message = "api_vip and api_host must come from the reserved public IP."
  }

  assert {
    condition     = output.jumphost.private_ip == "10.20.0.5" && output.jumphost.ssh_user == "suse" && length(output.nodes) == 0
    error_message = "jumphost must carry its addresses and ssh_user, and nodes must be empty."
  }

  assert {
    condition     = output.egress_ips == ["203.0.113.20"] && output.network.subnet_cidrs == ["10.20.0.0/21", "10.20.8.0/21"]
    error_message = "egress_ips must be the NAT address and the network two subnets."
  }
}

run "flex_shape_parsed" {
  command = plan

  variables {
    jumphost_instance_type = "VM.Standard.E5.Flex:4x32"
  }

  assert {
    condition = (
      oci_core_instance.jumphost[0].shape == "VM.Standard.E5.Flex" &&
      oci_core_instance.jumphost[0].shape_config[0].ocpus == 4 &&
      oci_core_instance.jumphost[0].shape_config[0].memory_in_gbs == 32
    )
    error_message = "A flex shape must split into shape, ocpus and memory."
  }
}

run "flex_shape_default" {
  command = plan

  assert {
    condition     = oci_core_instance.jumphost[0].shape_config[0].ocpus == 2 && oci_core_instance.jumphost[0].shape_config[0].memory_in_gbs == 16
    error_message = "The jumphost default is VM.Standard.E5.Flex:2x16."
  }
}

run "flex_shape_without_size" {
  command = plan

  variables {
    jumphost_instance_type = "VM.Standard.E5.Flex"
  }

  expect_failures = [terraform_data.input_checks]
}

run "fixed_shape_with_size" {
  command = plan

  variables {
    gpu_pools = { gpu = { instance_type = "VM.GPU.A10.1:2x16", count = 1 } }
  }

  expect_failures = [terraform_data.input_checks]
}

run "malformed_shape_size" {
  command = plan

  variables {
    jumphost_instance_type = "VM.Standard.E5.Flex:2-16"
  }

  expect_failures = [terraform_data.input_checks]
}

run "uefi_capability_schema" {
  command = plan

  assert {
    condition = (
      jsondecode(oci_core_compute_image_capability_schema.uefi[0].schema_data["Compute.Firmware"]).values == ["UEFI_64"] &&
      jsondecode(oci_core_compute_image_capability_schema.uefi[0].schema_data["Compute.Firmware"]).defaultValue == "UEFI_64"
    )
    error_message = "The image must get Compute.Firmware = UEFI_64."
  }

  assert {
    condition = (
      oci_core_image.ai_factory[0].launch_mode == "PARAVIRTUALIZED" &&
      oci_core_image.ai_factory[0].image_source_details[0].source_image_type == "QCOW2" &&
      oci_core_image.ai_factory[0].image_source_details[0].source_type == "objectStorageTuple"
    )
    error_message = "The image must import a QCOW2 from Object Storage in PARAVIRTUALIZED mode."
  }

  assert {
    condition     = contains(keys(oci_core_shape_management.gpu), "VM.GPU.A10.1")
    error_message = "The GPU shape of gpu_pools must be made compatible with the image."
  }
}

run "image_id_skips_chain" {
  command = plan

  variables {
    image_id = "ocid1.image.oc1..pinned"
  }

  assert {
    condition = alltrue([
      length(oci_core_image.ai_factory) == 0,
      length(oci_core_instance.jumphost) == 0,
      length(oci_objectstorage_bucket.build) == 0,
      length(terraform_data.image_ready) == 0,
      length(oci_core_compute_image_capability_schema.uefi) == 0,
    ])
    error_message = "image_id must skip the build, upload and import chain."
  }

  assert {
    condition     = output.image.ids["eu-frankfurt-1"] == "ocid1.image.oc1..pinned" && output.build_status == null && output.jumphost.public_ip == null
    error_message = "image_id must be reported as the image and leave no build host."
  }
}

run "deploy_nodes_rejects_public_ip" {
  command = plan

  variables {
    control_plane_public_ip = true
  }

  expect_failures = [terraform_data.input_checks]
}

run "pool_public_ip_rejected" {
  command = plan

  variables {
    gpu_pools = { gpu = { instance_type = "VM.GPU.A10.1", count = 1, public_ip = true } }
  }

  expect_failures = [terraform_data.input_checks]
}

run "pool_placement_rejected" {
  command = plan

  variables {
    worker_pools = { wrk = { instance_type = "VM.Standard.E5.Flex:2x16", count = 1, placement = "group" } }
  }

  expect_failures = [terraform_data.input_checks]
}

run "pool_bare_metal_rejected" {
  command = plan

  variables {
    gpu_pools = { gpu = { instance_type = "BM.GPU.A10.4", count = 1, kind = "bare_metal" } }
  }

  expect_failures = [terraform_data.input_checks]
}

run "labels" {
  command = plan

  assert {
    condition = alltrue([
      for k in ["elemental-cluster", "elemental-managed-by", "elemental-module", "elemental-created"] :
      contains(keys(oci_core_instance.jumphost[0].freeform_tags), k) &&
      contains(keys(oci_core_vcn.this[0].freeform_tags), k) &&
      contains(keys(oci_network_load_balancer_network_load_balancer.this.freeform_tags), k) &&
      contains(keys(oci_core_public_ip.nlb.freeform_tags), k) &&
      contains(keys(oci_objectstorage_bucket.build[0].freeform_tags), k) &&
      contains(keys(oci_core_image.ai_factory[0].freeform_tags), k)
    ]) && oci_core_instance.jumphost[0].freeform_tags["elemental-created"] == "20261113-123456"
    error_message = "Every taggable resource must carry the managed labels."
  }

  assert {
    condition = (
      oci_core_instance.jumphost[0].freeform_tags["elemental-role"] == "jumphost" &&
      oci_core_image.ai_factory[0].freeform_tags["elemental-role"] == "image" &&
      oci_core_public_ip.nlb.freeform_tags["elemental-role"] == "lb" &&
      contains(keys(oci_core_image.ai_factory[0].freeform_tags), "elemental-build")
    )
    error_message = "role and build labels are wrong."
  }
}

run "extra_tags" {
  command = plan

  variables {
    tags = { env = "test" }
  }

  assert {
    condition     = oci_core_vcn.this[0].freeform_tags["env"] == "test" && oci_core_vcn.this[0].freeform_tags["elemental-cluster"] == "out-oci"
    error_message = "tags must be added to the managed labels."
  }
}

run "firewall_rules" {
  command = plan

  assert {
    condition = alltrue([
      contains(keys(oci_core_network_security_group_security_rule.this), "jumphost-ssh-198.51.100.0/24"),
      contains(keys(oci_core_network_security_group_security_rule.this), "nlb-client-6443-198.51.100.0/24"),
      contains(keys(oci_core_network_security_group_security_rule.this), "nlb-client-9345-nat"),
      contains(keys(oci_core_network_security_group_security_rule.this), "control_plane-nlb-8080"),
      contains(keys(oci_core_network_security_group_security_rule.this), "agent-vxlan-from-control_plane"),
    ])
    error_message = "NSG rules must cover admin SSH, the API clients, the NAT joins, health checks and node ports."
  }

  assert {
    condition     = length([for k, r in oci_core_network_security_group_security_rule.this : k if k != "jumphost-ssh-198.51.100.0/24" && !endswith(k, "-ssh") && try(r.tcp_options[0].destination_port_range[0].min, 0) == 22]) == 0
    error_message = "Only the jumphost and its NSG sources may use port 22."
  }

  assert {
    condition     = length(oci_core_default_security_list.this[0].ingress_security_rules) == 1 && one(oci_core_default_security_list.this[0].ingress_security_rules).protocol == "1"
    error_message = "The default security list must open only ICMP fragmentation-needed inbound."
  }
}

run "load_balancer" {
  command = plan

  assert {
    condition = alltrue([
      length(oci_network_load_balancer_listener.this) == 4,
      contains(keys(oci_network_load_balancer_listener.this), "kube_api"),
      contains(keys(oci_network_load_balancer_backend_set.this), "supervisor"),
      !oci_network_load_balancer_backend_set.this["kube_api"].is_preserve_source,
      !oci_network_load_balancer_backend_set.this["supervisor"].is_preserve_source,
      !oci_network_load_balancer_backend_set.this["https"].is_preserve_source,
      oci_network_load_balancer_network_load_balancer.this.reserved_ips[0].id == "ocid1.publicip.oc1..nlb",
    ])
    error_message = "The NLB needs the four listeners and backend sets on the reserved IP, preserving the source on none."
  }
}

run "shape_not_offered" {
  command = plan

  variables {
    deploy_nodes        = true
    control_plane_count = 1
    gpu_pools           = { gpu = { instance_type = "VM.GPU.A10.2", count = 1 } }
  }

  expect_failures = [terraform_data.limits_check]
}

run "limit_too_low" {
  command = plan

  override_data {
    target          = data.oci_limits_resource_availability.this
    override_during = plan
    values          = { available = "0" }
  }

  expect_failures = [terraform_data.limits_check]
}

run "zone_unknown" {
  command = plan

  variables {
    zones = ["ad-3"]
  }

  expect_failures = [terraform_data.input_checks]
}

run "existing_network" {
  command = plan

  variables {
    vpc_id              = "ocid1.vcn.oc1..existing"
    public_subnet_id    = "ocid1.subnet.oc1..pub"
    private_subnet_id   = "ocid1.subnet.oc1..priv"
    deploy_nodes        = true
    control_plane_count = 1
    gpu_pools           = {}
  }

  assert {
    condition = alltrue([
      length(oci_core_vcn.this) == 0,
      length(oci_core_subnet.public) == 0,
      length(oci_core_subnet.private) == 0,
      length(oci_core_internet_gateway.this) == 0,
      length(oci_core_nat_gateway.this) == 0,
      length(oci_core_route_table.private) == 0,
      length(oci_core_default_security_list.this) == 0,
    ])
    error_message = "With vpc_id the module must not create or manage any network object."
  }

  assert {
    condition = alltrue([
      oci_core_network_security_group.this["nlb"].vcn_id == "ocid1.vcn.oc1..existing",
      oci_network_load_balancer_network_load_balancer.this.subnet_id == "ocid1.subnet.oc1..pub",
      oci_core_instance.node["out-oci-cp-01"].create_vnic_details[0].subnet_id == "ocid1.subnet.oc1..priv",
      oci_core_network_security_group_security_rule.this["control_plane-nlb-8080"].source == "10.30.0.0/24",
      oci_core_network_security_group_security_rule.this["nlb-client-9345-nat"].source == "198.51.100.77/32",
    ])
    error_message = "NSGs, NLB and nodes must use the existing VCN, subnets, public subnet CIDR and NAT address."
  }

  assert {
    condition = alltrue([
      output.egress_ips == ["198.51.100.77"],
      output.network.vpc_cidr == "10.30.0.0/16",
      output.network.subnet_cidrs == ["10.30.0.0/24", "10.30.8.0/22"],
      output.provider_details.vcn_id == "ocid1.vcn.oc1..existing",
      output.provider_details.nat_gateway_id == "ocid1.natgateway.oc1..nat",
      output.provider_details.subnet_ids.private == "ocid1.subnet.oc1..priv",
    ])
    error_message = "Outputs must report the existing network, its first CIDR block and the NAT address."
  }
}

run "existing_network_partial" {
  command = plan

  variables {
    vpc_id = "ocid1.vcn.oc1..existing"
  }

  expect_failures = [var.public_subnet_id]
}

run "existing_network_vpc_cidr_mismatch" {
  command = plan

  variables {
    vpc_id            = "ocid1.vcn.oc1..existing"
    public_subnet_id  = "ocid1.subnet.oc1..pub"
    private_subnet_id = "ocid1.subnet.oc1..priv"
    vpc_cidr          = "10.40.0.0/16"
  }

  expect_failures = [terraform_data.input_checks]
}

run "existing_network_subnet_outside_cidr" {
  command = plan

  variables {
    vpc_id            = "ocid1.vcn.oc1..existing"
    public_subnet_id  = "ocid1.subnet.oc1..pub"
    private_subnet_id = "ocid1.subnet.oc1..priv"
  }

  override_data {
    target          = data.oci_core_vcn.existing
    override_during = plan
    values          = { compartment_id = "ocid1.compartment.oc1..net", cidr_blocks = ["10.30.0.0/24", "10.30.8.0/22"] }
  }

  expect_failures = [terraform_data.input_checks]
}

run "existing_network_rke2_overlap" {
  command = plan

  variables {
    vpc_id            = "ocid1.vcn.oc1..existing"
    public_subnet_id  = "ocid1.subnet.oc1..pub"
    private_subnet_id = "ocid1.subnet.oc1..priv"
  }

  override_data {
    target          = data.oci_core_vcn.existing
    override_during = plan
    values          = { compartment_id = "ocid1.compartment.oc1..net", cidr_blocks = ["10.0.0.0/8"] }
  }

  expect_failures = [terraform_data.input_checks]
}

run "existing_network_subnet_other_vcn" {
  command = plan

  variables {
    vpc_id            = "ocid1.vcn.oc1..existing"
    public_subnet_id  = "ocid1.subnet.oc1..pub"
    private_subnet_id = "ocid1.subnet.oc1..priv"
  }

  override_data {
    target          = data.oci_core_subnet.private
    override_during = plan
    values = {
      vcn_id              = "ocid1.vcn.oc1..other", cidr_block = "10.30.8.0/22", route_table_id = "ocid1.routetable.oc1..priv"
      availability_domain = null, prohibit_public_ip_on_vnic = true
    }
  }

  expect_failures = [terraform_data.input_checks]
}

run "existing_network_ad_specific_subnet" {
  command = plan

  variables {
    vpc_id            = "ocid1.vcn.oc1..existing"
    public_subnet_id  = "ocid1.subnet.oc1..pub"
    private_subnet_id = "ocid1.subnet.oc1..priv"
  }

  override_data {
    target          = data.oci_core_subnet.private
    override_during = plan
    values = {
      vcn_id              = "ocid1.vcn.oc1..existing", cidr_block = "10.30.8.0/22", route_table_id = "ocid1.routetable.oc1..priv"
      availability_domain = "KiWy:EU-FRANKFURT-1-AD-1", prohibit_public_ip_on_vnic = true
    }
  }

  expect_failures = [terraform_data.input_checks]
}

run "existing_network_public_prohibits_public_ip" {
  command = plan

  variables {
    vpc_id            = "ocid1.vcn.oc1..existing"
    public_subnet_id  = "ocid1.subnet.oc1..pub"
    private_subnet_id = "ocid1.subnet.oc1..priv"
  }

  override_data {
    target          = data.oci_core_subnet.public
    override_during = plan
    values = {
      vcn_id              = "ocid1.vcn.oc1..existing", cidr_block = "10.30.0.0/24", route_table_id = "ocid1.routetable.oc1..pub"
      availability_domain = null, prohibit_public_ip_on_vnic = true
    }
  }

  expect_failures = [terraform_data.input_checks]
}

run "existing_network_wrong_routes" {
  command = plan

  variables {
    vpc_id            = "ocid1.vcn.oc1..existing"
    public_subnet_id  = "ocid1.subnet.oc1..pub"
    private_subnet_id = "ocid1.subnet.oc1..priv"
  }

  # Swapped targets: the public subnet routes to the NAT gateway, the private one to the internet gateway.
  override_data {
    target          = data.oci_core_route_tables.existing
    override_during = plan
    values = {
      route_tables = [
        for t in [["pub", "ocid1.natgateway.oc1..nat"], ["priv", "ocid1.internetgateway.oc1..igw"]] : {
          compartment_id = "ocid1.compartment.oc1..net", defined_tags = {}, display_name = t[0], freeform_tags = {}
          id             = "ocid1.routetable.oc1..${t[0]}", state = "AVAILABLE", time_created = null, vcn_id = "ocid1.vcn.oc1..existing"
          route_rules    = [{ cidr_block = null, description = null, destination = "0.0.0.0/0", destination_type = "CIDR_BLOCK", network_entity_id = t[1], route_type = null }]
        }
      ]
    }
  }

  expect_failures = [terraform_data.input_checks]
}
