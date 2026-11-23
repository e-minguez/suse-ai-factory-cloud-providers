# Plans examples/gcp with one catalog tfvars file (make test-catalog passes it
# with -var-file), so a validation or precondition change that breaks a shape
# fails CI. Google provider mocked; no cloud calls. Variables below stand in for
# clusters/common-*.tfvars; the CA stands in for addons.auto.tfvars.json.

mock_provider "google" {
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
  target          = module.ai_factory.data.google_client_config.this
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
  target          = module.ai_factory.data.google_compute_zones.region
  override_during = plan
  values = {
    id    = "projects/dummy-project/regions/europe-west4"
    names = ["europe-west4-a", "europe-west4-b", "europe-west4-c"]
  }
}

override_data {
  target          = module.ai_factory.data.google_compute_machine_types.this
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
  target          = module.ai_factory.data.http.region
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
  target          = module.ai_factory.data.http.project
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
  target          = module.ai_factory.data.http.existing_instances
  override_during = plan
  values = {
    status_code   = 200
    response_body = "{}"
  }
}

override_data {
  target          = module.ai_factory.data.http.existing_addresses
  override_during = plan
  values = {
    status_code   = 200
    response_body = "{}"
  }
}

override_resource {
  target          = module.ai_factory.google_compute_address.external_lb
  override_during = plan
  values = {
    address = "203.0.113.10"
  }
}

override_resource {
  target          = module.ai_factory.google_compute_address.internal_lb
  override_during = plan
  values = {
    address = "10.20.0.100"
  }
}

override_resource {
  target          = module.ai_factory.google_compute_address.nat
  override_during = plan
  values = {
    address   = "203.0.113.20"
    self_link = "https://www.googleapis.com/compute/v1/projects/dummy-project/regions/europe-west4/addresses/nat"
  }
}

override_resource {
  target          = module.ai_factory.google_compute_image.ai_factory
  override_during = plan
  values = {
    self_link = "https://www.googleapis.com/compute/v1/projects/dummy-project/global/images/gcp-test-built"
  }
}

override_resource {
  target          = module.ai_factory.random_password.token
  override_during = plan
  values          = { result = "dummytokendummytokendummytoken00" }
}

override_resource {
  target          = module.ai_factory.module.config.random_password.rancher_bootstrap
  override_during = plan
  values          = { result = "dummybootstrapdummybootstrap0000" }
}

override_resource {
  target          = module.ai_factory.time_static.created
  override_during = plan
  values          = { rfc3339 = "2026-11-13T12:34:56Z" }
}

variables {
  gcp_project                   = "dummy-project"
  region                        = "europe-west4"
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
}

run "shape_plans" {
  command = plan
}
