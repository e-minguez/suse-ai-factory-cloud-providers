# Plans examples/azure with one catalog tfvars file (make test-catalog passes it
# with -var-file), so a validation or precondition change that breaks a shape
# fails CI. azurerm and azapi mocked; no cloud calls. Credentials below stand in
# for clusters/common-*.tfvars; the CA stands in for addons.auto.tfvars.json.
# A new VM size used by a shape goes in the sizes list and its family in the usages.

# Resource IDs that other resources parse at plan time need a valid shape; the
# default mock IDs are random strings that OpenTofu's provider rejects.
mock_provider "azurerm" {
  override_during = plan

  mock_resource "azurerm_storage_account" {
    defaults = { id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/dummy/providers/Microsoft.Storage/storageAccounts/dummy" }
  }
  mock_resource "azurerm_subnet" {
    defaults = { id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/dummy/providers/Microsoft.Network/virtualNetworks/dummy/subnets/dummy" }
  }
  mock_resource "azurerm_lb" {
    defaults = { id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/dummy/providers/Microsoft.Network/loadBalancers/dummy" }
  }
  mock_resource "azurerm_shared_image_version" {
    defaults = { id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/dummy/providers/Microsoft.Compute/galleries/dummy/images/dummy/versions/1.0.1" }
  }
  mock_resource "azurerm_lb_backend_address_pool" {
    defaults = { id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/dummy/providers/Microsoft.Network/loadBalancers/dummy/backendAddressPools/dummy" }
  }
  mock_resource "azurerm_network_security_group" {
    defaults = { id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/dummy/providers/Microsoft.Network/networkSecurityGroups/dummy" }
  }
  mock_resource "azurerm_application_security_group" {
    defaults = { id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/dummy/providers/Microsoft.Network/applicationSecurityGroups/dummy" }
  }
  mock_resource "azurerm_virtual_network" {
    defaults = { id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/dummy/providers/Microsoft.Network/virtualNetworks/dummy" }
  }
  mock_resource "azurerm_resource_group" {
    defaults = { id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/dummy" }
  }
  mock_resource "azurerm_nat_gateway" {
    defaults = { id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/dummy/providers/Microsoft.Network/natGateways/dummy" }
  }
}
mock_provider "azapi" {
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

# VM sizes the subscription sees in the region: size, family, zones, restrictions, capabilities.
override_data {
  target          = module.ai_factory.data.azapi_resource_list.skus
  override_during = plan
  values = {
    output = {
      sizes = [
        {
          name         = "Standard_D4s_v5", family = "standardDSv5Family", zones = ["1", "2", "3"], restrictions = []
          capabilities = [{ name = "vCPUs", value = "4" }, { name = "HyperVGenerations", value = "V1,V2" }, { name = "PremiumIO", value = "True" }, { name = "AcceleratedNetworkingEnabled", value = "True" }, { name = "DiskControllerTypes", value = "SCSI" }]
        },
        {
          name         = "Standard_D8s_v5", family = "standardDSv5Family", zones = ["1", "2", "3"], restrictions = []
          capabilities = [{ name = "vCPUs", value = "8" }, { name = "HyperVGenerations", value = "V1,V2" }, { name = "PremiumIO", value = "True" }, { name = "AcceleratedNetworkingEnabled", value = "True" }, { name = "DiskControllerTypes", value = "SCSI" }]
        },
        {
          name         = "Standard_D32s_v5", family = "standardDSv5Family", zones = ["1", "2", "3"], restrictions = []
          capabilities = [{ name = "vCPUs", value = "32" }, { name = "HyperVGenerations", value = "V1,V2" }, { name = "PremiumIO", value = "True" }, { name = "AcceleratedNetworkingEnabled", value = "True" }, { name = "DiskControllerTypes", value = "SCSI" }]
        },
        {
          name         = "Standard_NC4as_T4_v3", family = "standardNCASv3_T4Family", zones = ["1", "2", "3"], restrictions = []
          capabilities = [{ name = "vCPUs", value = "4" }, { name = "HyperVGenerations", value = "V1,V2" }, { name = "PremiumIO", value = "True" }, { name = "AcceleratedNetworkingEnabled", value = "True" }, { name = "DiskControllerTypes", value = "SCSI" }]
        },
        {
          name         = "Standard_NC16as_T4_v3", family = "standardNCASv3_T4Family", zones = ["1", "2", "3"], restrictions = []
          capabilities = [{ name = "vCPUs", value = "16" }, { name = "HyperVGenerations", value = "V1,V2" }, { name = "PremiumIO", value = "True" }, { name = "AcceleratedNetworkingEnabled", value = "True" }, { name = "DiskControllerTypes", value = "SCSI" }]
        },
      ]
    }
  }
}

override_data {
  target          = module.ai_factory.data.azapi_resource_action.compute_usages
  override_during = plan
  values = {
    output = {
      usages = [
        { name = "cores", current = 0, limit = 1000 },
        { name = "standardDSv5Family", current = 0, limit = 1000 },
        { name = "standardNCASv3_T4Family", current = 0, limit = 1000 },
      ]
    }
  }
}

override_data {
  target          = module.ai_factory.data.azapi_resource_action.network_usages
  override_during = plan
  values = {
    output = {
      usages = [
        { name = "StandardSkuPublicIPAddresses", current = 0, limit = 100 },
        { name = "StandardSkuLoadBalancers", current = 0, limit = 100 },
      ]
    }
  }
}

override_data {
  target          = module.ai_factory.data.azapi_resource_list.existing_vms
  override_during = plan
  values          = { output = { vms = [] } }
}

override_data {
  target          = module.ai_factory.data.azapi_resource_list.existing_public_ips
  override_during = plan
  values          = { output = { ips = [] } }
}

override_data {
  target          = module.ai_factory.data.azapi_resource_list.existing_lbs
  override_during = plan
  values          = { output = { lbs = [] } }
}

override_data {
  target          = module.ai_factory.data.azapi_resource_action.locations
  override_during = plan
  values          = { output = { zones = ["1", "2", "3"] } }
}

override_data {
  target          = module.ai_factory.data.azurerm_storage_account_blob_container_sas.write[0]
  override_during = plan
  values          = { sas = "?sv=2022-11-02&sig=WRITESIG" }
}

override_data {
  target          = module.ai_factory.data.azurerm_storage_account_blob_container_sas.operator[0]
  override_during = plan
  values          = { sas = "?sv=2022-11-02&sig=OPERATORSIG" }
}

override_resource {
  target          = module.ai_factory.azurerm_public_ip.lb
  override_during = plan
  values          = { id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/dummy/providers/Microsoft.Network/publicIPAddresses/lb", ip_address = "203.0.113.10" }
}

override_resource {
  target          = module.ai_factory.azurerm_public_ip.nat[0]
  override_during = plan
  values          = { id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/dummy/providers/Microsoft.Network/publicIPAddresses/nat", ip_address = "203.0.113.20" }
}

override_resource {
  target          = module.ai_factory.azurerm_public_ip.jumphost[0]
  override_during = plan
  values          = { id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/dummy/providers/Microsoft.Network/publicIPAddresses/jumphost", ip_address = "203.0.113.11" }
}

override_resource {
  target          = module.ai_factory.azurerm_network_interface.jumphost[0]
  override_during = plan
  values          = { id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/dummy/providers/Microsoft.Network/networkInterfaces/jumphost", private_ip_address = "10.20.0.5" }
}

override_resource {
  target          = module.ai_factory.azurerm_network_interface.node
  override_during = plan
  values          = { id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/dummy/providers/Microsoft.Network/networkInterfaces/node", private_ip_address = "10.20.8.10" }
}

override_resource {
  target          = module.ai_factory.time_static.created
  override_during = plan
  values          = { rfc3339 = "2026-11-13T12:34:56Z" }
}

variables {
  azure_subscription_id         = "00000000-1111-2222-3333-444444444444"
  region                        = "westeurope"
  admin_cidrs                   = ["198.51.100.0/24"]
  root_password_hash            = "$6$DUMMYSALT$ROOTDUMMYHASHROOTDUMMYHASHROOTDUMMYHASHROOTDUMMYHASHROOTDUMMYHASH0"
  node_user_password_hash       = "$6$DUMMYSALT$NODEDUMMYHASHNODEDUMMYHASHNODEDUMMYHASHNODEDUMMYHASHNODEDUMMYHASH0"
  ssh_authorized_keys           = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGUeJySRXuZUM/7X5U/XJA1igArCUc0Z8FrAZupL1y5O test"]
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
