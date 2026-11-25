# Plans examples/harvester with one catalog tfvars file (make test-catalog passes it
# with -var-file), so a validation or precondition change that breaks a shape
# fails CI. Harvester mocked; no cluster calls. Values below stand in for
# clusters/common-*.tfvars; the CA stands in for addons.auto.tfvars.json.

mock_provider "harvester" {
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
  target          = module.ai_factory.data.harvester_network.this
  override_during = plan
  values = {
    id                   = "harvester-public/vlan-2006"
    cluster_network_name = "mgmt"
    config               = "{\"cniVersion\":\"0.3.1\",\"name\":\"vlan-2006\",\"type\":\"bridge\",\"bridge\":\"mgmt-br\",\"vlan\":2006}"
    description          = null
    labels               = {}
    tags                 = {}
    message              = null
    route_cidr           = null
    route_connectivity   = null
    route_dhcp_server_ip = null
    route_gateway        = null
    route_mode           = null
    state                = "Active"
    vlan_id              = 2006
  }
}

override_data {
  target          = module.ai_factory.data.harvester_storageclass.this
  override_during = plan
  values = {
    id                     = "fast"
    allow_volume_expansion = true
    allowed_topologies     = []
    description            = null
    is_default             = false
    labels                 = {}
    tags                   = {}
    message                = null
    parameters             = {}
    reclaim_policy         = "Delete"
    state                  = null
    volume_binding_mode    = "Immediate"
    volume_provisioner     = "driver.longhorn.io"
  }
}

override_data {
  target          = module.ai_factory.data.harvester_image.buildhost
  override_during = plan
  values = {
    id                        = "harvester-public/leap-16"
    backend                   = "backing-image"
    state                     = "Imported"
    source_type               = "download"
    labels                    = {}
    tags                      = {}
    storage_class_parameters  = {}
    volume_storage_class_name = "longhorn-leap-16"
    storage_class_name        = null
    url                       = null
    checksum                  = null
    description               = null
    file_path                 = null
    message                   = null
    progress                  = 100
    pvc_name                  = null
    pvc_namespace             = null
    security_parameters       = {}
    size                      = 1
  }
}

override_data {
  target          = module.ai_factory.data.harvester_image.node
  override_during = plan
  values = {
    id                        = "harvester-public/aif-node"
    backend                   = "backing-image"
    state                     = "Imported"
    source_type               = "export-from-volume"
    labels                    = {}
    tags                      = {}
    storage_class_parameters  = {}
    volume_storage_class_name = "longhorn-aif-node"
    storage_class_name        = null
    url                       = null
    checksum                  = null
    description               = null
    file_path                 = null
    message                   = null
    progress                  = 100
    pvc_name                  = null
    pvc_namespace             = null
    security_parameters       = {}
    size                      = 8
  }
}

override_resource {
  target          = module.ai_factory.harvester_image.buildhost
  override_during = plan
  values          = { id = "suse-ai-factory-on-harvester/buildhost-image" }
}

override_resource {
  target          = module.ai_factory.harvester_image.node
  override_during = plan
  values          = { id = "suse-ai-factory-on-harvester/node-image" }
}

override_resource {
  target          = module.ai_factory.harvester_virtualmachine.buildhost
  override_during = plan
  values = {
    network_interface = {
      interface_name = "default"
      ip_address     = "10.114.128.50"
    }
  }
}

override_resource {
  target          = module.ai_factory.harvester_virtualmachine.node
  override_during = plan
  values = {
    id = "suse-ai-factory-on-harvester/node"
    network_interface = {
      interface_name = "default"
      ip_address     = ""
    }
  }
}

override_resource {
  target          = module.ai_factory.time_static.created
  override_during = plan
  values          = { rfc3339 = "2026-11-18T12:34:56Z" }
}

variables {
  harvester_kubeconfig_path     = "/dev/null"
  harvester_namespace           = "suse-ai-factory-on-harvester"
  vpc_id                        = "harvester-public/vlan-2006"
  vpc_cidr                      = "10.114.128.0/25"
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
