locals {
  write_node_ip_script = templatefile("${path.module}/templates/elemental/network/write-node-ip.sh.tftpl", { vpc_cidr = var.vpc_cidr })

  extra_units_yaml = length(var.extra_butane_units) == 0 ? "" : trimspace(yamlencode([
    for u in var.extra_butane_units : { for k, v in u : k => v if v != null }
  ]))

  enabled_iscsi_prep      = contains(local.enabled_sysexts, "suse-storage")
  enabled_local_path_prep = contains(local.enabled_components, "local-path-provisioner")
  suse_storage_enabled    = contains(local.enabled_components, "suse-storage")

  # Config dir contents keyed by path relative to it, with comments.
  elemental_files_documented = merge(
    var.extra_config_files,
    {
      "release.yaml" = templatefile("${path.module}/templates/elemental/release.yaml.tftpl", {
        components     = local.enabled_specs
        sysexts        = local.enabled_sysexts
        appco_set      = local.appco_set
        appco_username = var.appco_username
        appco_password = var.appco_password
      })

      "install.yaml" = templatefile("${path.module}/templates/elemental/install.yaml.tftpl", {
        kernel_cmdline = var.kernel_cmdline
        disk_size      = var.image_disk_size
        fips           = var.fips
      })

      "butane.yaml" = templatefile("${path.module}/templates/elemental/butane.yaml.tftpl", {
        root_password_hash      = var.root_password_hash
        ssh_authorized_keys     = var.ssh_authorized_keys
        node_username           = var.node_username
        node_user_password_hash = var.node_user_password_hash
        permit_root_ssh         = var.permit_root_ssh
        enable_write_node_ip    = var.enable_write_node_ip
        write_node_ip_script    = local.write_node_ip_script
        enable_iscsi_prep       = local.enabled_iscsi_prep
        iscsi_prep_script       = file("${path.module}/templates/elemental/storage/iscsi-prep.sh")
        enable_local_path_prep  = local.enabled_local_path_prep
        extra_units_yaml        = local.extra_units_yaml
        extra_files             = var.extra_butane_files
      })

      "kubernetes/cluster.yaml" = templatefile("${path.module}/templates/elemental/kubernetes/cluster.yaml.tftpl", {
        api_vip      = var.api_vip
        api_vip_mode = var.api_vip_mode
        api_host     = var.api_host
      })

      "kubernetes/config/server.yaml" = templatefile("${path.module}/templates/elemental/kubernetes/config/server.yaml.tftpl", {
        token              = var.rke2_token
        ingress_controller = var.ingress_controller
        tls_san            = var.tls_san
        node_username      = var.node_username
      })

      "kubernetes/config/agent.yaml" = templatefile("${path.module}/templates/elemental/kubernetes/config/agent.yaml.tftpl", {
        token = var.rke2_token
      })
    },
    local.component_values_files,
    local.component_pull_secret_manifests,
    var.ingress_controller != "traefik" ? {} : {
      "kubernetes/manifests/traefik.yaml" = templatefile("${path.module}/templates/elemental/kubernetes/manifests/traefik.yaml.tftpl", {
        vpc_cidr = var.vpc_cidr
      })
    },
  )

  # Delivered through per-node Ignition, not the image; stripped with the rest.
  canal_manifest_documented = templatefile("${path.module}/templates/elemental/kubernetes/manifests/canal.yaml.tftpl", {
    iface_regex = var.canal_iface_regex
    veth_mtu    = var.pod_veth_mtu
  })

  # Wrapped in slashes, so replace() reads them as regexes. Drops lines whose
  # first non-blank character is "#" (keeping "#!"), then collapses blank runs.
  strip_comment_lines = "/(?m)^[ \\t]*#(?:[^!].*)?\\n/"
  collapse_blank_runs = "/\\n{3,}/"

  # The one comment-stripping pass: every rendered file and Ignition payload.
  stripped = {
    for path, content in merge(local.elemental_files_documented, { "@canal" = local.canal_manifest_documented }) :
    path => replace(replace(content, local.strip_comment_lines, ""), local.collapse_blank_runs, "\n\n")
  }

  canal_manifest = local.stripped["@canal"]

  # The release manifest is shipped as-is: it is data, not a commented template.
  elemental_files = merge(
    { for path, content in local.stripped : path => content if path != "@canal" },
    { "release_manifest.yaml" = local.release_manifest },
  )

  # The rebuild counter is mixed in only when > 0, so 0 leaves the hash unchanged.
  build_inputs = merge(
    {
      files                  = local.elemental_files
      manifest               = local.manifest_body
      image                  = var.elemental_image
      core_platform_override = var.core_platform_override
      sysext_overrides       = local.effective_sysext_overrides
      extra                  = var.extra_build_inputs
    },
    var.image_rebuild > 0 ? { rebuild = var.image_rebuild } : {},
  )

  # Hash of every build input: the only rebuild trigger in the providers.
  build_hash = nonsensitive(sha256(jsonencode(local.build_inputs)))
}
