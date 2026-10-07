# Everything baked into the image (release.yaml, butane.yaml, RKE2 config, Helm
# values) and every node's Ignition user_data come from the shared module.
# build_hash is the only rebuild trigger (image.tf, build.tf).
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

  # The API takes 32768 base64 characters, about 24 KiB of payload.
  user_data_max_bytes = 24576
  kernel_cmdline      = "console=ttyS0,115200n8 console=tty0 quiet ignition.platform.id=exoscale"

  canal_iface_regex  = local.vpc_iface_regex
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
  rancher_bootstrap_password = var.rancher_bootstrap_password

  # Every node has a public and a privnet NIC: pin RKE2 to the privnet one.
  enable_write_node_ip = true

  extra_butane_units = local.node_units
  extra_butane_files = local.node_unit_files

  # The factory script is provider-owned and not in the config dir.
  image_rebuild = var.image_rebuild

  extra_build_inputs = {
    factory = module.image_factory.script_hash
  }
}

# Units baked into the image. node-hostname: pool members share one Ignition
# entry, so the hostname and RKE2 node-name come from metadata. wait-privnet:
# pool NICs are hot-plugged, so write-node-ip waits for the privnet address.
# RKE2 requires both.
locals {
  node_unit_specs = {
    "node-hostname" = {
      description = "Set the hostname and RKE2 node-name from the metadata service"
      before      = "rke2-server.service rke2-agent.service"
    }
    "wait-privnet" = {
      description = "Wait for the private network address"
      before      = "write-node-ip.service rke2-server.service rke2-agent.service"
    }
  }

  node_units = [
    for name, u in local.node_unit_specs : {
      name     = "${name}.service"
      enabled  = true
      contents = <<-EOT
        [Unit]
        Description=${u.description}
        Wants=network-online.target
        After=network-online.target
        Before=${u.before}

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart=/usr/bin/bash /var/lib/elemental/${name}.sh

        [Install]
        WantedBy=multi-user.target
        RequiredBy=rke2-server.service rke2-agent.service
      EOT
    }
  ]

  # Scripts live in /var/lib/elemental, as write-node-ip.sh: the image's other
  # paths are read-only during Ignition.
  node_unit_files = [
    { path = "/var/lib/elemental/node-hostname.sh", contents = file("${path.module}/templates/node/node-hostname.sh") },
    {
      path = "/var/lib/elemental/wait-privnet.sh"
      contents = templatefile("${path.module}/templates/node/wait-privnet.sh.tftpl", {
        vpc_cidr        = local.vpc_cidr
        timeout_seconds = local.privnet_wait_seconds
      })
    },
  ]
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

# The jumphost builds and serves the qcow2; exoscale_template imports it, so
# `terraform destroy` removes the template. Order: jumphost build,
# terraform_data.image_served (poll), MD5 read, template, nodes. A new
# build_hash rotates random_id.serve_path (build.tf), replacing jumphost and template.

locals {
  # image_base is also the template name, e.g. "suse-ai-factory-1a2b3c4d5e6f".
  image_base = "${var.cluster_name}-${module.config.build_id}"
  image_url  = "http://${exoscale_compute_instance.jumphost.public_ip_address}/${random_id.serve_path.hex}/${local.image_base}.qcow2"
}

# Jumphost and build host in state for scripts/lib/ssh.sh during the apply;
# outputs reach the state file only after the template exists.
resource "terraform_data" "build_access" {
  count = var.image_id == null ? 1 : 0

  input = {
    build_id     = module.config.build_id
    jumphost     = local.jumphost_access
    build_status = local.build_status_value
  }
}

# Port 80 for the template fetcher. A resource, so it cannot be created and
# removed in one apply: deploy.sh pass 2 sets image_import_port_open = false,
# pass 1 resets it when the template is created.
resource "exoscale_security_group_rule" "image_import" {
  count = var.image_import_port_open ? 1 : 0

  security_group_id = exoscale_security_group.jumphost.id
  type              = "INGRESS"
  protocol          = "TCP"
  cidr              = "0.0.0.0/0"
  start_port        = 80
  end_port          = 80
  description       = "elemental image import"
}

# Waits until the qcow2 is served, or image_build_timeout runs out. Polled from
# the operator machine over the public path the fetcher uses.
resource "terraform_data" "image_served" {
  count = var.image_id == null ? 1 : 0

  depends_on = [exoscale_security_group_rule.image_import]

  triggers_replace = [random_id.serve_path.hex]
  input            = local.image_url

  provisioner "local-exec" {
    command = "${path.module}/scripts/wait-for-image.sh"
    environment = {
      IMAGE_URL       = local.image_url
      TIMEOUT_SECONDS = local.image_build_timeout
      POLL_SECONDS    = 30
    }
  }
}

# The template needs the MD5 at create time; the jumphost writes it next to the
# image. depends_on defers the read to the apply that builds. Read only while
# port 80 is open: afterwards the template ignores the checksum.
data "http" "image_md5" {
  count = var.image_id == null && var.image_import_port_open ? 1 : 0

  depends_on = [terraform_data.image_served]

  url = "${local.image_url}.md5"

  retry {
    attempts = 3
  }

  lifecycle {
    postcondition {
      condition     = self.status_code == 200 && can(regex("^[0-9a-f]{32}$", trimspace(self.response_body)))
      error_message = "The jumphost returned HTTP ${self.status_code} for ${local.image_url}.md5 instead of an MD5 sum. Check the build log: ${local.helper["build-logs"]}"
    }
  }
}

resource "exoscale_template" "ai_factory" {
  count = var.image_id == null ? 1 : 0

  zone             = local.zone
  name             = local.image_base
  description      = "SUSE AI Factory Elemental image, build ${module.config.build_id}"
  url              = local.image_url
  checksum         = try(trimspace(one(data.http.image_md5[*].response_body)), "")
  boot_mode        = "uefi"
  password_enabled = false
  ssh_key_enabled  = false

  timeouts {
    create = "60m"
  }

  # url embeds the jumphost IP and is only read at create; checksum is read
  # only while port 80 is open. A new build replaces the template.
  lifecycle {
    ignore_changes       = [url, checksum]
    replace_triggered_by = [random_id.serve_path]
  }
}

locals {
  # one(): the template has count = 0 when image_id is set.
  effective_template_id = var.image_id != null ? var.image_id : one(exoscale_template.ai_factory[*].id)
}

# Templates of earlier builds: Exoscale refuses to delete a template while
# instances from it run, and a rebuild keeps the control plane members. deploy.sh
# moves the replaced template here in state; Terraform only holds it and
# deletes it on destroy, after the pool (docs/decisions/008-exoscale-module.md).
resource "exoscale_template" "retained" {
  for_each = toset(var.retained_template_ids)

  # Required by the schema only: every argument is ignored.
  zone             = local.zone
  name             = "${var.cluster_name}-retained"
  url              = "http://retained.invalid/${each.key}.qcow2"
  checksum         = "00000000000000000000000000000000"
  boot_mode        = "uefi"
  password_enabled = false
  ssh_key_enabled  = false

  lifecycle {
    ignore_changes = all
  }
}
