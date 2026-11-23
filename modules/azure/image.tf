# Everything baked into the image (release.yaml, butane.yaml, RKE2 config, Helm
# values) and every node's Ignition user_data come from the shared module.
# build_hash is the only rebuild trigger.
module "config" {
  source = "../elemental-config"

  cluster_name = var.cluster_name
  api_vip      = local.api_vip
  api_host     = local.api_host
  api_vip_mode = local.api_vip_mode
  vpc_cidr     = local.vpc_cidr
  tls_san      = []
  rke2_token   = random_password.token.result

  nodes = [
    for n in local.ignition_nodes : {
      hostname = n.hostname
      type     = n.type
      role     = n.role
      init     = n.init
      pool     = n.pool
    }
  ]

  # user_data is limited to 64 KB; the base64 text of 46000 bytes is about 61 KB.
  user_data_max_bytes = 46000
  kernel_cmdline      = "console=ttyS0,115200n8 console=tty0 quiet ignition.platform.id=azure"

  pod_veth_mtu       = local.pod_veth_mtu
  ingress_controller = var.ingress_controller
  components         = var.components
  suse_storage_nodes = var.suse_storage_nodes

  elemental_image = var.elemental_image
  image_disk_size = var.image_disk_size
  fips            = var.fips

  root_password_hash      = var.root_password_hash
  node_user_password_hash = var.node_user_password_hash
  ssh_authorized_keys     = var.ssh_authorized_keys
  node_username           = var.node_username
  permit_root_ssh         = var.permit_root_ssh

  aif_release            = var.aif_release
  core_platform_override = var.core_platform_override
  sysext_image_overrides = var.sysext_image_overrides

  appco_username         = var.appco_username
  appco_password         = var.appco_password
  appco_registry         = var.appco_registry
  suse_registry_username = var.suse_registry_username
  suse_registry_password = var.suse_registry_password
  nvidia_api_key         = var.nvidia_api_key
  nvidia_username        = var.nvidia_username
  gpu_driver_repository  = var.gpu_driver_repository
  gpu_driver_version     = var.gpu_driver_version

  rancher_hostname           = local.rancher_hostname
  ingress_domain             = var.ingress_domain
  rancher_bootstrap_password = var.rancher_bootstrap_password

  ingress_address = local.api_vip

  security_admin_password              = var.security_admin_password
  security_hostname                    = var.security_hostname
  security_join_token                  = var.security_join_token
  security_primary_endpoint            = var.security_primary_endpoint
  security_rancher_url                 = var.security_rancher_url
  observability_license_key            = var.observability_license_key
  observability_admin_password         = var.observability_admin_password
  observability_sizing_profile         = var.observability_sizing_profile
  observability_hostname               = var.observability_hostname
  observability_bootstrap_token        = var.observability_bootstrap_token
  observability_server_url             = var.observability_server_url
  observability_ca_pem                 = var.observability_ca_pem
  observability_allowed_origins        = var.observability_allowed_origins
  observability_suse_ai_namespace      = var.observability_suse_ai_namespace
  observability_opensearch_credentials = var.observability_opensearch_credentials

  # Single NIC per node: RKE2 picks the right address without write-node-ip.
  enable_write_node_ip = false

  extra_butane_units = local.node_units
  extra_butane_files = local.node_unit_files

  # The factory script is provider-owned and not in the config dir.
  image_rebuild = var.image_rebuild

  extra_build_inputs = {
    factory = module.image_factory.script_hash
  }
}

# Warns rather than fails: some pre-release tags ship a manifest whose
# metadata.version differs from the tag. Skipped for a manifest URL.
check "aif_release_matches_manifest" {
  assert {
    condition = (
      can(regex("^https?://", var.aif_release)) ||
      try(yamldecode(module.config.release_manifest).metadata.version, "") == var.aif_release
    )
    error_message = "aif_release is \"${var.aif_release}\", but the manifest at tag aif-operator-${var.aif_release} declares metadata.version ${try(yamldecode(module.config.release_manifest).metadata.version, "(unreadable)")}, and that is what will be built."
  }
}

# Units and scripts baked into the image (scripts in /var/lib/elemental: other
# paths are read-only during Ignition). azure-report-ready: all nodes.
# azure-lb-hairpin (+ timer): control planes only, no-op on agents (ADR 015).
locals {
  hairpin_api_ports = join(" ", [for k, v in module.rke2_ports.lb_api : v.from])

  node_units = [
    {
      name     = "azure-report-ready.service"
      enabled  = true
      contents = <<-EOT
        [Unit]
        Description=Report ready to the Azure WireServer
        Wants=network-online.target
        After=network-online.target

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        TimeoutStartSec=16min
        ExecStart=/usr/bin/bash /var/lib/elemental/azure-report-ready.sh

        [Install]
        WantedBy=multi-user.target
      EOT
    },
    {
      name     = "azure-lb-hairpin.service"
      enabled  = false
      contents = <<-EOT
        [Unit]
        Description=Redirect load balancer frontend traffic to this control plane
        Wants=network-online.target
        After=network-online.target

        [Service]
        Type=oneshot
        ExecStart=/usr/bin/bash /var/lib/elemental/azure-lb-hairpin.sh
      EOT
    },
    {
      name     = "azure-lb-hairpin.timer"
      enabled  = true
      contents = <<-EOT
        [Unit]
        Description=Check the local control plane for the load balancer redirect

        [Timer]
        OnBootSec=30s
        OnUnitActiveSec=15s
        AccuracySec=1s

        [Install]
        WantedBy=timers.target
      EOT
    },
  ]

  node_unit_files = [
    { path = "/var/lib/elemental/azure-report-ready.sh", contents = file("${path.module}/templates/node/azure-report-ready.sh") },
    {
      path = "/var/lib/elemental/azure-lb-hairpin.sh"
      contents = templatefile("${path.module}/templates/node/azure-lb-hairpin.sh.tftpl", {
        vip       = local.api_vip
        api_ports = local.hairpin_api_ports
      })
    },
  ]
}

# Page blob -> Azure Compute Gallery image. The jumphost (build.tf) only
# uploads; Terraform owns the gallery, so `terraform destroy` removes it. An
# image_id pinned that way must not be one this module owns.
locals {
  # image_base is also the blob name, e.g. "suse-ai-factory-1a2b3c4d5e6f".
  image_base = "${var.cluster_name}-${module.config.build_id}"

  # Gallery names allow letters, digits, "_" and "."; no hyphens.
  gallery_name = "${replace(var.cluster_name, "-", "_")}_gallery"
  # Versions are Major.Minor.Patch integers: the patch is the first 28 bits of build_hash.
  image_version = "1.0.${parseint(substr(module.config.build_hash, 0, 7), 16)}"
}

resource "azurerm_shared_image_gallery" "this" {
  count = local.build_image ? 1 : 0

  name                = local.gallery_name
  location            = local.region
  resource_group_name = local.resource_group_name
  tags                = merge(local.labels, { "elemental-role" = "image" })
}

# Generation 2 (UEFI) with SCSI and NVMe disk controllers, no Trusted Launch:
# Secure Boot would need a signed shim and kernel, and the NVIDIA driver expects it off.
resource "azurerm_shared_image" "this" {
  count = local.build_image ? 1 : 0

  name                                = "${var.cluster_name}-elemental"
  gallery_name                        = azurerm_shared_image_gallery.this[0].name
  resource_group_name                 = local.resource_group_name
  location                            = local.region
  os_type                             = "Linux"
  hyper_v_generation                  = "V2"
  specialized                         = false
  disk_controller_type_nvme_enabled   = true
  accelerated_network_support_enabled = true
  trusted_launch_supported            = false
  tags                                = merge(local.labels, { "elemental-role" = "image" })

  identifier {
    publisher = "elemental"
    offer     = var.cluster_name
    sku       = "ai-factory"
  }
}

resource "azurerm_shared_image_version" "this" {
  count = local.build_image ? 1 : 0

  depends_on = [terraform_data.image_ready]

  name                = local.image_version
  gallery_name        = azurerm_shared_image_gallery.this[0].name
  image_name          = azurerm_shared_image.this[0].name
  resource_group_name = local.resource_group_name
  location            = local.region
  blob_uri            = "${local.container_url}/${local.vhd_name}"
  storage_account_id  = azurerm_storage_account.build[0].id
  tags = merge(local.labels, {
    "elemental-role"  = "image"
    "elemental-build" = module.config.build_id
  })

  target_region {
    name                   = local.region
    regional_replica_count = 1
    storage_account_type   = "Standard_LRS"
  }

  timeouts {
    create = "120m"
  }
}

# The gallery keeps its own copy: the uploaded VHD is not needed once the
# version exists. keep_build_artifacts keeps it; Terraform destroys the
# storage account with it.
resource "terraform_data" "vhd_cleanup" {
  count = local.build_image && !var.keep_build_artifacts ? 1 : 0

  depends_on = [azurerm_shared_image_version.this]

  triggers_replace = [local.image_base]

  provisioner "local-exec" {
    command = "${path.module}/scripts/delete-blob.sh"
    environment = {
      BLOB_URL = local.vhd_url
    }
  }
}

locals {
  # one(): the image version has count = 0 when image_id is set.
  effective_image_id = var.image_id != null ? var.image_id : one(azurerm_shared_image_version.this[*].id)
}
