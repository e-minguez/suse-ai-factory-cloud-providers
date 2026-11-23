# Asserts the network: created and existing virtual network, subnets and NAT gateway, input checks on
# the network inputs, and the NSG rules. Azure mocked; no cloud calls.

mock_provider "azurerm" {
  override_during = plan
}
mock_provider "azapi" {
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

# VM sizes the subscription sees in the region: size, family, zones, restrictions, capabilities.
override_data {
  target          = data.azapi_resource_list.skus
  override_during = plan
  values = {
    output = {
      sizes = [
        {
          name         = "Standard_D8s_v5", family = "standardDSv5Family", zones = ["1", "2", "3"], restrictions = []
          capabilities = [{ name = "vCPUs", value = "8" }, { name = "HyperVGenerations", value = "V1,V2" }, { name = "PremiumIO", value = "True" }, { name = "AcceleratedNetworkingEnabled", value = "True" }, { name = "DiskControllerTypes", value = "SCSI" }]
        },
        {
          name         = "Standard_D4s_v5", family = "standardDSv5Family", zones = ["1", "2", "3"], restrictions = []
          capabilities = [{ name = "vCPUs", value = "4" }, { name = "HyperVGenerations", value = "V1,V2" }, { name = "PremiumIO", value = "True" }, { name = "AcceleratedNetworkingEnabled", value = "True" }, { name = "DiskControllerTypes", value = "SCSI" }]
        },
        {
          name         = "Standard_D8ds_v6", family = "standardDDSv6Family", zones = ["1", "2", "3"], restrictions = []
          capabilities = [{ name = "vCPUs", value = "8" }, { name = "HyperVGenerations", value = "V2" }, { name = "PremiumIO", value = "True" }, { name = "AcceleratedNetworkingEnabled", value = "True" }, { name = "DiskControllerTypes", value = "SCSI, NVMe" }]
        },
        {
          name         = "Standard_NC24ads_A100_v4", family = "standardNCADSA100v4Family", zones = ["1", "2"], restrictions = []
          capabilities = [{ name = "vCPUs", value = "24" }, { name = "HyperVGenerations", value = "V1,V2" }, { name = "PremiumIO", value = "True" }, { name = "AcceleratedNetworkingEnabled", value = "True" }, { name = "DiskControllerTypes", value = "SCSI" }]
        },
      ]
    }
  }
}

override_data {
  target          = data.azapi_resource_action.compute_usages
  override_during = plan
  values = {
    output = {
      usages = [
        { name = "cores", current = 10, limit = 200 },
        { name = "standardDSv5Family", current = 0, limit = 100 },
        { name = "standardDDSv6Family", current = 0, limit = 100 },
        { name = "standardNCADSA100v4Family", current = 0, limit = 100 },
      ]
    }
  }
}

override_data {
  target          = data.azapi_resource_action.network_usages
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
  target          = data.azapi_resource_list.existing_vms
  override_during = plan
  values          = { output = { vms = [] } }
}

override_data {
  target          = data.azapi_resource_list.existing_public_ips
  override_during = plan
  values          = { output = { ips = [] } }
}

override_data {
  target          = data.azapi_resource_list.existing_lbs
  override_during = plan
  values          = { output = { lbs = [] } }
}

override_data {
  target          = data.azapi_resource_action.locations
  override_during = plan
  values          = { output = { zones = ["1", "2", "3"] } }
}

override_data {
  target          = data.azurerm_storage_account_blob_container_sas.write[0]
  override_during = plan
  values          = { sas = "?sv=2022-11-02&sig=WRITESIG" }
}

override_data {
  target          = data.azurerm_storage_account_blob_container_sas.operator[0]
  override_during = plan
  values          = { sas = "?sv=2022-11-02&sig=OPERATORSIG" }
}

override_resource {
  target          = azurerm_public_ip.lb
  override_during = plan
  values          = { id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/dummy/providers/Microsoft.Network/publicIPAddresses/lb", ip_address = "203.0.113.10" }
}

override_resource {
  target          = azurerm_public_ip.nat[0]
  override_during = plan
  values          = { id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/dummy/providers/Microsoft.Network/publicIPAddresses/nat", ip_address = "203.0.113.20" }
}

override_resource {
  target          = azurerm_public_ip.jumphost[0]
  override_during = plan
  values          = { id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/dummy/providers/Microsoft.Network/publicIPAddresses/jumphost", ip_address = "203.0.113.11" }
}

override_resource {
  target          = azurerm_network_interface.jumphost[0]
  override_during = plan
  values          = { id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/dummy/providers/Microsoft.Network/networkInterfaces/jumphost", private_ip_address = "10.20.0.5" }
}

override_resource {
  target          = azurerm_network_interface.node
  override_during = plan
  values          = { id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/dummy/providers/Microsoft.Network/networkInterfaces/node", private_ip_address = "10.20.8.10" }
}

override_resource {
  target          = azurerm_shared_image_version.this[0]
  override_during = plan
  values          = { id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/dummy/providers/Microsoft.Compute/galleries/dummy_gallery/images/dummy-elemental/versions/1.0.1" }
}

override_resource {
  target          = random_password.token
  override_during = plan
  values          = { result = "dummytokendummytokendummytoken1234" }
}

override_resource {
  target          = azurerm_application_security_group.this["control_plane"]
  override_during = plan
  values          = { id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/dummy/providers/Microsoft.Network/applicationSecurityGroups/control-plane" }
}

override_resource {
  target          = azurerm_application_security_group.this["agent"]
  override_during = plan
  values          = { id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/dummy/providers/Microsoft.Network/applicationSecurityGroups/agent" }
}

override_resource {
  target          = azurerm_resource_group.this[0]
  override_during = plan
  values          = { id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/dummy" }
}

override_resource {
  target          = azurerm_virtual_network.this[0]
  override_during = plan
  values          = { id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/dummy/providers/Microsoft.Network/virtualNetworks/dummy" }
}

override_resource {
  target          = azurerm_subnet.public[0]
  override_during = plan
  values          = { id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/dummy/providers/Microsoft.Network/virtualNetworks/dummy/subnets/public" }
}

override_resource {
  target          = azurerm_subnet.private[0]
  override_during = plan
  values          = { id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/dummy/providers/Microsoft.Network/virtualNetworks/dummy/subnets/private" }
}

override_resource {
  target          = azurerm_nat_gateway.this[0]
  override_during = plan
  values          = { id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/dummy/providers/Microsoft.Network/natGateways/dummy" }
}

override_resource {
  target          = azurerm_network_security_group.this
  override_during = plan
  values          = { id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/dummy/providers/Microsoft.Network/networkSecurityGroups/dummy" }
}

override_resource {
  target          = azurerm_lb.this
  override_during = plan
  values          = { id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/dummy/providers/Microsoft.Network/loadBalancers/dummy" }
}

override_resource {
  target          = azurerm_lb_backend_address_pool.control_plane
  override_during = plan
  values          = { id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/dummy/providers/Microsoft.Network/loadBalancers/dummy/backendAddressPools/control-plane" }
}

override_resource {
  target          = azurerm_lb_probe.this
  override_during = plan
  values          = { id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/dummy/providers/Microsoft.Network/loadBalancers/dummy/probes/dummy" }
}

override_resource {
  target          = azurerm_storage_account.build[0]
  override_during = plan
  values          = { id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/dummy/providers/Microsoft.Storage/storageAccounts/dummy" }
}

override_resource {
  target          = time_static.created
  override_during = plan
  values          = { rfc3339 = "2026-11-13T12:34:56Z" }
}

variables {
  azure_subscription_id      = "00000000-1111-2222-3333-444444444444"
  region                     = "westeurope"
  admin_cidrs                = ["198.51.100.0/24"]
  api_cidrs                  = ["198.51.100.0/24"]
  root_password_hash         = "$6$DUMMYSALT$ROOTDUMMYHASHROOTDUMMYHASHROOTDUMMYHASHROOTDUMMYHASHROOTDUMMYHASH0"
  node_user_password_hash    = "$6$DUMMYSALT$NODEDUMMYHASHNODEDUMMYHASHNODEDUMMYHASHNODEDUMMYHASHNODEDUMMYHASH0"
  ssh_authorized_keys        = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGUeJySRXuZUM/7X5U/XJA1igArCUc0Z8FrAZupL1y5O test"]
  appco_username             = "DUMMY-APPCO-USER"
  suse_registry_username     = "DUMMY-REGCODE"
  suse_registry_password     = "DUMMY-REGISTRY-PASSWORD"
  appco_password             = "DUMMY-APPCO-PASSWORD"
  nvidia_api_key             = "DUMMY-NVIDIA-API-KEY"
  rancher_bootstrap_password = "DUMMY-RANCHER-BOOTSTRAP"
  cluster_name               = "net-az"
  deploy_nodes               = true
  gpu_pools                  = {}
}

# Existing network, used by the runs that set vpc_id: a /16 with a /24 public
# and a /22 private subnet, the private one behind a NAT gateway.
override_data {
  target          = data.azurerm_virtual_network.existing[0]
  override_during = plan
  values = {
    location      = "westeurope"
    address_space = ["10.30.0.0/16"]
  }
}

override_data {
  target          = data.azurerm_subnet.existing["public"]
  override_during = plan
  values          = { address_prefixes = ["10.30.0.0/24"] }
}

override_data {
  target          = data.azurerm_subnet.existing["private"]
  override_during = plan
  values          = { address_prefixes = ["10.30.8.0/22"] }
}

override_data {
  target          = data.azapi_resource.existing_subnet["public"]
  override_during = plan
  values          = { output = { properties = {} } }
}

override_data {
  target          = data.azapi_resource.existing_subnet["private"]
  override_during = plan
  values = {
    output = { properties = { natGateway = { id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/natGateways/nat" } } }
  }
}

override_data {
  target          = data.azapi_resource.existing_nat[0]
  override_during = plan
  values = {
    output = {
      properties = {
        publicIpAddresses = [{ id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/publicIPAddresses/nat" }]
        publicIpPrefixes  = [{ id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/publicIPPrefixes/natprefix" }]
      }
    }
  }
}

override_data {
  target          = data.azapi_resource.existing_nat_ips["/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/publicIPAddresses/nat"]
  override_during = plan
  values          = { output = { properties = { ipAddress = "198.51.100.77" } } }
}

override_data {
  target          = data.azapi_resource.existing_nat_prefixes["/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/publicIPPrefixes/natprefix"]
  override_during = plan
  values          = { output = { properties = { ipPrefix = "203.0.113.64/28" } } }
}

run "created_network" {
  command = plan

  assert {
    condition = (
      azurerm_virtual_network.this[0].name == "net-az" &&
      contains(azurerm_virtual_network.this[0].address_space, "10.20.0.0/20") &&
      azurerm_subnet.public[0].name == "net-az-public" && azurerm_subnet.public[0].address_prefixes[0] == "10.20.0.0/21" &&
      azurerm_subnet.private[0].name == "net-az-private" && azurerm_subnet.private[0].address_prefixes[0] == "10.20.8.0/21" &&
      !azurerm_subnet.public[0].default_outbound_access_enabled && !azurerm_subnet.private[0].default_outbound_access_enabled
    )
    error_message = "The module creates a virtual network split into a public and a private subnet without default outbound access."
  }

  assert {
    condition = (
      azurerm_resource_group.this[0].name == "net-az" && azurerm_resource_group.this[0].location == "westeurope" &&
      length(data.azurerm_resource_group.existing) == 0 &&
      azurerm_nat_gateway.this[0].sku_name == "Standard" && azurerm_public_ip.nat[0].sku == "Standard" &&
      length(azurerm_subnet_nat_gateway_association.private) == 1
    )
    error_message = "The module creates its resource group and a NAT gateway for the private subnet."
  }

  assert {
    condition     = jsonencode(output.egress_ips) == jsonencode(["203.0.113.20"]) && output.network.vpc_cidr == "10.20.0.0/20" && jsonencode(output.network.subnet_cidrs) == jsonencode(["10.20.0.0/21", "10.20.8.0/21"])
    error_message = "Outputs must report the created network and the NAT address."
  }
}

run "existing_resource_group" {
  command = plan

  variables {
    resource_group_name = "shared-rg"
  }

  assert {
    condition = (
      length(azurerm_resource_group.this) == 0 && length(data.azurerm_resource_group.existing) == 1 &&
      output.provider_details.resource_group == "shared-rg"
    )
    error_message = "With resource_group_name the module reads that group and creates none."
  }
}

run "existing_network" {
  command = plan

  variables {
    vpc_id              = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/virtualNetworks/vnet"
    public_subnet_id    = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/pub"
    private_subnet_id   = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/priv"
    control_plane_count = 1
  }

  assert {
    condition = alltrue([
      length(azurerm_virtual_network.this) == 0,
      length(azurerm_subnet.public) == 0,
      length(azurerm_subnet.private) == 0,
      length(azurerm_public_ip.nat) == 0,
      length(azurerm_nat_gateway.this) == 0,
      length(azurerm_nat_gateway_public_ip_association.this) == 0,
      length(azurerm_subnet_nat_gateway_association.private) == 0,
    ])
    error_message = "With vpc_id the module must not create or manage any network object."
  }

  assert {
    condition = alltrue([
      azurerm_network_interface.node["net-az-cp-01"].ip_configuration[0].subnet_id == var.private_subnet_id,
      azurerm_network_interface.jumphost[0].ip_configuration[0].subnet_id == var.public_subnet_id,
      output.provider_details.virtual_network_id == var.vpc_id,
      output.provider_details.subnet_ids.private == var.private_subnet_id,
      output.provider_details.subnet_ids.public == var.public_subnet_id,
    ])
    error_message = "NICs and outputs must use the existing virtual network and subnets."
  }

  assert {
    condition = alltrue([
      jsonencode(output.egress_ips) == jsonencode(["198.51.100.77", "203.0.113.64/28"]),
      output.network.vpc_cidr == "10.30.0.0/16",
      jsonencode(output.network.subnet_cidrs) == jsonencode(["10.30.0.0/24", "10.30.8.0/22"]),
      endswith(output.provider_details.nat_gateway_id, "/natGateways/nat"),
    ])
    error_message = "Outputs must report the existing network, its first address space and the NAT gateway address."
  }

  assert {
    condition = alltrue([
      for r in azurerm_network_security_group.this["control_plane"].security_rule : r.name != "ssh" || try(contains(r.source_address_prefixes, "10.30.0.0/24"), false)
    ]) && contains([for r in azurerm_network_security_group.this["control_plane"].security_rule : try(contains(r.source_address_prefixes, "198.51.100.77/32") && contains(r.source_address_prefixes, "203.0.113.64/28"), false)], true)
    error_message = "SSH comes from the existing public subnet and every NAT address and prefix is a client of the load balancer rules."
  }
}

run "existing_network_vpc_cidr_set" {
  command = plan

  variables {
    vpc_cidr          = "10.30.0.0/16"
    vpc_id            = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/virtualNetworks/vnet"
    public_subnet_id  = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/pub"
    private_subnet_id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/priv"
  }

  assert {
    condition     = output.network.vpc_cidr == "10.30.0.0/16"
    error_message = "A vpc_cidr that is an address space of the virtual network is accepted."
  }
}

run "existing_network_missing_private_subnet" {
  command = plan

  variables {
    vpc_id           = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/virtualNetworks/vnet"
    public_subnet_id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/pub"
  }

  expect_failures = [var.private_subnet_id]
}

run "existing_network_missing_public_subnet" {
  command = plan

  variables {
    vpc_id            = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/virtualNetworks/vnet"
    private_subnet_id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/priv"
  }

  expect_failures = [var.public_subnet_id]
}

run "subnets_without_vpc_id" {
  command = plan

  variables {
    public_subnet_id  = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/pub"
    private_subnet_id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/priv"
  }

  expect_failures = [var.public_subnet_id]
}

run "existing_network_same_subnet" {
  command = plan

  variables {
    vpc_id            = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/virtualNetworks/vnet"
    public_subnet_id  = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/pub"
    private_subnet_id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/pub"
  }

  expect_failures = [var.private_subnet_id]
}

run "existing_network_other_subscription" {
  command = plan

  variables {
    vpc_id            = "/subscriptions/99999999-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/virtualNetworks/vnet"
    public_subnet_id  = "/subscriptions/99999999-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/pub"
    private_subnet_id = "/subscriptions/99999999-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/priv"
  }

  expect_failures = [terraform_data.input_checks]
}

run "existing_network_no_nat_gateway" {
  command = plan

  variables {
    vpc_id            = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/virtualNetworks/vnet"
    public_subnet_id  = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/pub"
    private_subnet_id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/priv"
  }

  override_data {
    target          = data.azapi_resource.existing_subnet["private"]
    override_during = plan
    values          = { output = { properties = {} } }
  }

  expect_failures = [terraform_data.input_checks]
}

run "existing_network_vpc_cidr_mismatch" {
  command = plan

  variables {
    vpc_cidr          = "10.99.0.0/16"
    vpc_id            = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/virtualNetworks/vnet"
    public_subnet_id  = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/pub"
    private_subnet_id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/priv"
  }

  expect_failures = [terraform_data.input_checks]
}

run "existing_network_subnet_outside_cidr" {
  command = plan

  variables {
    vpc_id            = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/virtualNetworks/vnet"
    public_subnet_id  = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/pub"
    private_subnet_id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/priv"
  }

  override_data {
    target          = data.azurerm_subnet.existing["private"]
    override_during = plan
    values          = { address_prefixes = ["192.168.8.0/22"] }
  }

  expect_failures = [terraform_data.input_checks]
}

run "existing_network_other_region" {
  command = plan

  variables {
    vpc_id            = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/virtualNetworks/vnet"
    public_subnet_id  = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/pub"
    private_subnet_id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/priv"
  }

  override_data {
    target          = data.azurerm_virtual_network.existing[0]
    override_during = plan
    values = {
      location      = "northeurope"
      address_space = ["10.30.0.0/16"]
    }
  }

  expect_failures = [terraform_data.input_checks]
}

run "existing_network_subnet_of_other_vnet" {
  command = plan

  variables {
    vpc_id            = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/virtualNetworks/vnet"
    public_subnet_id  = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/pub"
    private_subnet_id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/virtualNetworks/other/subnets/priv"
  }

  expect_failures = [terraform_data.input_checks]
}

run "rke2_cidr_overlap" {
  command = plan

  variables {
    vpc_id            = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/virtualNetworks/vnet"
    public_subnet_id  = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/pub"
    private_subnet_id = "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/net-rg/providers/Microsoft.Network/virtualNetworks/vnet/subnets/priv"
  }

  # The virtual network (and so vpc_cidr) is the RKE2 default pod network.
  override_data {
    target          = data.azurerm_virtual_network.existing[0]
    override_during = plan
    values = {
      location      = "westeurope"
      address_space = ["10.42.0.0/16"]
    }
  }

  expect_failures = [terraform_data.input_checks]
}

run "vpc_cidr_too_small" {
  command = plan

  variables {
    vpc_cidr = "10.20.0.0/28"
  }

  expect_failures = [terraform_data.input_checks]
}

run "mtu_above_virtual_network_frame" {
  command = plan

  variables {
    vpc_mtu = 9000
  }

  expect_failures = [terraform_data.input_checks]
}

run "nsg_rules" {
  command = plan

  variables {
    ingress_cidrs = ["192.0.2.0/24"]
  }

  assert {
    condition = (
      length(azurerm_network_security_group.this) == 3 &&
      alltrue([for n, g in azurerm_network_security_group.this : g.name == "net-az-${replace(n, "_", "-")}"])
    )
    error_message = "One NSG per role: jumphost, control_plane, agent."
  }

  assert {
    condition = alltrue([
      for n, g in azurerm_network_security_group.this :
      [for r in g.security_rule : r if r.name == "deny-all-inbound"][0].priority == 4096 &&
      [for r in g.security_rule : r if r.name == "deny-all-inbound"][0].access == "Deny" &&
      alltrue([for r in g.security_rule : r.direction == "Inbound"])
    ])
    error_message = "Every NSG ends with a deny-all inbound rule at priority 4096 and only has inbound rules."
  }

  assert {
    condition = (
      length(azurerm_network_security_group.this["jumphost"].security_rule) == 2 &&
      [for r in azurerm_network_security_group.this["jumphost"].security_rule : r if r.name == "ssh"][0].destination_port_range == "22" &&
      jsonencode([for r in azurerm_network_security_group.this["jumphost"].security_rule : r if r.name == "ssh"][0].source_address_prefixes) == jsonencode(["198.51.100.0/24"])
    )
    error_message = "The jumphost admits SSH from admin_cidrs only."
  }

  assert {
    condition = (
      jsonencode([for r in azurerm_network_security_group.this["control_plane"].security_rule : r if r.name == "client-6443"][0].source_address_prefixes) == jsonencode(["198.51.100.0/24", "203.0.113.20/32"]) &&
      jsonencode([for r in azurerm_network_security_group.this["control_plane"].security_rule : r if r.name == "client-9345"][0].source_address_prefixes) == jsonencode(["203.0.113.20/32"]) &&
      jsonencode([for r in azurerm_network_security_group.this["control_plane"].security_rule : r if r.name == "client-443"][0].source_address_prefixes) == jsonencode(["192.0.2.0/24", "203.0.113.20/32"]) &&
      jsonencode([for r in azurerm_network_security_group.this["control_plane"].security_rule : r if r.name == "client-80"][0].source_address_prefixes) == jsonencode(["192.0.2.0/24", "203.0.113.20/32"])
    )
    error_message = "api_cidrs filter 6443, ingress_cidrs 80 and 443; the NAT address is a client of every listener and the only one of the supervisor port."
  }

  assert {
    condition = (
      [for r in azurerm_network_security_group.this["control_plane"].security_rule : r if r.name == "lb-probe-6443"][0].source_address_prefix == "AzureLoadBalancer" &&
      [for r in azurerm_network_security_group.this["control_plane"].security_rule : r if r.name == "lb-probe-8080"][0].source_address_prefix == "AzureLoadBalancer" &&
      [for r in azurerm_network_security_group.this["control_plane"].security_rule : r if r.name == "etcd"][0].destination_port_range == "2379-2381" &&
      length([for r in azurerm_network_security_group.this["control_plane"].security_rule : r if r.name == "etcd"][0].source_application_security_group_ids) == 1 &&
      length([for r in azurerm_network_security_group.this["control_plane"].security_rule : r if r.name == "nodes-6443"][0].source_application_security_group_ids) == 2 &&
      jsonencode([for r in azurerm_network_security_group.this["control_plane"].security_rule : r if r.name == "ssh"][0].source_address_prefixes) == jsonencode(["10.20.0.0/21"])
    )
    error_message = "The control-plane group admits the probe from the AzureLoadBalancer tag, etcd from control planes, node ports from both roles and SSH from the public subnet."
  }

  assert {
    condition = (
      !contains([for r in azurerm_network_security_group.this["agent"].security_rule : r.name], "client-6443") &&
      !contains([for r in azurerm_network_security_group.this["agent"].security_rule : r.name], "etcd") &&
      contains([for r in azurerm_network_security_group.this["agent"].security_rule : r.name], "nodes-kubelet") &&
      contains([for r in azurerm_network_security_group.this["agent"].security_rule : r.name], "ssh")
    )
    error_message = "Agents admit no client, API or etcd traffic: node ports and SSH only."
  }

  assert {
    condition = (
      length(azurerm_network_interface_security_group_association.node) == 3 &&
      length(azurerm_network_interface_application_security_group_association.node) == 3 &&
      length(azurerm_application_security_group.this) == 2
    )
    error_message = "NSGs and application security groups attach to the NICs (and not to subnets) of every node."
  }
}

run "nsg_rules_follow_ingress_controller" {
  command = plan

  variables {
    ingress_controller = "none"
  }

  assert {
    condition = alltrue([
      for r in azurerm_network_security_group.this["control_plane"].security_rule : r.name != "client-443" && r.name != "client-80" && r.name != "lb-probe-8080"
    ]) && contains([for r in azurerm_network_security_group.this["control_plane"].security_rule : r.name], "client-6443")
    error_message = "Without an ingress controller only the API and supervisor ports are open."
  }
}
