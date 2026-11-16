# Plans examples/oci with one catalog tfvars file (make test-catalog passes it
# with -var-file), so a validation or precondition change that breaks a shape
# fails CI. OCI mocked; no cloud calls. Credentials below stand in for
# clusters/common-*.tfvars; the CA stands in for addons.auto.tfvars.json.

mock_provider "oci" {
  override_during = plan
}
mock_provider "http" {}

override_data {
  target = module.ai_factory.module.config.data.http.aif_release_manifest
  values = {
    status_code   = 200
    response_body = file("../../modules/elemental-config/tests/fixtures/release_manifest.yaml")
  }
}

override_data {
  target          = module.ai_factory.data.oci_identity_availability_domains.this
  override_during = plan
  values = {
    availability_domains = [
      { compartment_id = "ocid1.tenancy.oc1..dummy", id = "ocid1.availabilitydomain.oc1..ad1", name = "KiWy:EU-FRANKFURT-1-AD-1" },
    ]
  }
}

override_data {
  target          = module.ai_factory.data.oci_core_shapes.zone
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
  target          = module.ai_factory.data.oci_core_instances.existing
  override_during = plan
  values          = { instances = [] }
}

override_data {
  target          = module.ai_factory.data.oci_network_load_balancer_network_load_balancers.existing
  override_during = plan
  values          = { network_load_balancer_collection = [] }
}

override_data {
  target          = module.ai_factory.data.oci_core_public_ips.existing
  override_during = plan
  values          = { public_ips = [] }
}

override_data {
  target          = module.ai_factory.data.oci_limits_resource_availability.this
  override_during = plan
  values          = { available = "1000" }
}

override_data {
  target          = module.ai_factory.data.oci_core_compute_global_image_capability_schemas.this
  override_during = plan
  values = {
    compute_global_image_capability_schemas = [
      { compartment_id = null, current_version_name = "1.0.0", defined_tags = {}, display_name = "Global", freeform_tags = {}, id = "ocid1.computeglobalimagecapabilityschema.oc1..dummy", time_created = null },
    ]
  }
}

override_data {
  target          = module.ai_factory.data.oci_objectstorage_namespace.this
  override_during = plan
  values          = { namespace = "dummyns" }
}

override_resource {
  target          = module.ai_factory.oci_core_public_ip.nlb
  override_during = plan
  values = {
    id         = "ocid1.publicip.oc1..nlb"
    ip_address = "203.0.113.10"
  }
}

override_resource {
  target          = module.ai_factory.oci_core_nat_gateway.this
  override_during = plan
  values          = { nat_ip = "203.0.113.20" }
}

override_resource {
  target          = module.ai_factory.oci_core_instance.jumphost
  override_during = plan
  values = {
    public_ip  = "203.0.113.11"
    private_ip = "10.20.0.5"
  }
}

override_resource {
  target          = module.ai_factory.oci_core_instance.node
  override_during = plan
  values = {
    id         = "ocid1.instance.oc1..node"
    private_ip = "10.20.8.10"
  }
}

override_resource {
  target          = module.ai_factory.time_static.created
  override_during = plan
  values          = { rfc3339 = "2026-11-13T12:34:56Z" }
}

variables {
  oci_tenancy_ocid              = "ocid1.tenancy.oc1..dummy"
  oci_user_ocid                 = "ocid1.user.oc1..dummy"
  oci_fingerprint               = "aa:bb:cc:dd"
  oci_private_key_path          = "/dev/null"
  oci_compartment_ocid          = "ocid1.compartment.oc1..dummy"
  region                        = "eu-frankfurt-1"
  admin_cidrs                   = ["198.51.100.0/24"]
  root_password_hash            = "$6$DUMMYSALT$ROOTDUMMYHASHROOTDUMMYHASHROOTDUMMYHASHROOTDUMMYHASHROOTDUMMYHASH0"
  node_user_password_hash       = "$6$DUMMYSALT$NODEDUMMYHASHNODEDUMMYHASHNODEDUMMYHASHNODEDUMMYHASHNODEDUMMYHASH0"
  ssh_authorized_keys           = ["ssh-ed25519 AAAADUMMY test"]
  appco_username                = "DUMMY-APPCO-USER"
  appco_password                = "DUMMY-APPCO-PASSWORD"
  suse_registry_username        = "DUMMY-REGCODE"
  suse_registry_password        = "DUMMY-REGISTRY-PASSWORD"
  nvidia_api_key                = "DUMMY-NVIDIA-API-KEY"
  security_join_token           = "00000000-0000-4000-8000-000000000000"
  observability_bootstrap_token = "DUMMY-BOOTSTRAP-TOKEN"
  observability_ca_pem          = "-----BEGIN CERTIFICATE-----\nDUMMY\n-----END CERTIFICATE-----\n"
  observability_license_key     = "DUMMY-LICENSE"
  jumphost_image                = "ocid1.image.oc1..jumphost"
}

run "shape_plans" {
  command = plan
}
