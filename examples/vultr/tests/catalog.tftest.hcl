# Plans examples/vultr with one catalog tfvars file (make test-catalog passes it
# with -var-file), so a validation or precondition change that breaks a shape
# fails CI. Vultr mocked; no cloud calls. Credentials below stand in for
# clusters/common-*.tfvars; the CA stands in for addons.auto.tfvars.json.

mock_provider "vultr" {
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

# Every plan used by a catalog file must be listed here.
override_data {
  target = module.ai_factory.data.http.plan_availability
  values = {
    status_code = 200
    response_body = jsonencode({ available_plans = [
      "vx1-g-4c-16g-240s", "vx1-g-8c-32g-480s", "vx1-g-16c-64g-960s", "vc2-6c-16gb", "vc2-8c-32gb",
      "vcg-a40-24c-120g-48vram",
    ] })
  }
}

override_data {
  target          = module.ai_factory.data.http.lb
  override_during = plan
  values = {
    status_code   = 200
    response_body = jsonencode({ load_balancer = { ipv4 = "203.0.113.10" } })
  }
}

override_data {
  target          = module.ai_factory.data.http.agent_existing["instances"]
  override_during = plan
  values = {
    status_code   = 200
    response_body = jsonencode({ instances = [] })
  }
}

override_data {
  target          = module.ai_factory.data.http.agent_existing["bare-metals"]
  override_during = plan
  values = {
    status_code   = 200
    response_body = jsonencode({ bare_metals = [] })
  }
}

# OpenTofu mocks computed lists as empty and the module indexes private_ips[0].
override_resource {
  target          = module.ai_factory.vultr_nat_gateway.this
  override_during = plan
  values          = { public_ips = ["198.51.100.7"], private_ips = ["10.20.0.1"] }
}

override_resource {
  target          = module.ai_factory.vultr_load_balancer.api
  override_during = plan
  values          = { id = "00000000-0000-0000-0000-000000000001" }
}

override_resource {
  target          = module.ai_factory.vultr_load_balancer.ingress
  override_during = plan
  values          = { id = "00000000-0000-0000-0000-000000000002" }
}

override_resource {
  target          = module.ai_factory.vultr_instance.jumphost
  override_during = plan
  values = {
    main_ip     = "203.0.113.11"
    internal_ip = "10.20.0.5"
  }
}

override_resource {
  target          = module.ai_factory.time_static.created
  override_during = plan
  values          = { rfc3339 = "2026-09-30T12:34:56Z" }
}

variables {
  vultr_api_key                 = "DUMMY-VULTR-KEY"
  region                        = "ams"
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
