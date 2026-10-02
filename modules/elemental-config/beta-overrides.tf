# Beta workarounds, removed together once a GA OS image ships elemental3ctl >= 3.1
# (see docs/workarounds.md): sysext image overrides and the core platform
# manifest flatten, both applied to the release manifest at plan time.

locals {
  # Overrides narrowed to extensions an enabled component pulls in, so the
  # default override stays inert until suse-storage is selected.
  effective_sysext_overrides = {
    for name, image in var.sysext_image_overrides : name => image
    if contains(local.enabled_sysexts, name)
  }

  manifest_body    = data.http.aif_release_manifest.response_body
  rewrite_manifest = var.core_platform_override != null || length(local.effective_sysext_overrides) > 0

  # jsondecode(string) keeps both branches the same type; nothing is decoded
  # when no rewrite is needed.
  aif_manifest = jsondecode(local.rewrite_manifest ? jsonencode(yamldecode(local.manifest_body)) : "{}")

  aif_components = try(local.aif_manifest.components, {})
  aif_extensions = try(local.aif_components.systemd.extensions, [])

  manifest_extension_names = [for e in local.aif_extensions : e.name]

  unknown_sysext_overrides = sort(setsubtract(toset(keys(local.effective_sysext_overrides)), toset(local.manifest_extension_names)))

  # merge() with lookup() keeps every element one object type, which a
  # conditional between the original and the rewritten element would not.
  rewritten_extensions = [
    for e in local.aif_extensions : merge(e, { image = lookup(local.effective_sysext_overrides, e.name, e.image) })
  ]

  rewritten_aif_components = merge(local.aif_components, try(
    { systemd = merge(local.aif_components.systemd, { extensions = local.rewritten_extensions }) }, {}
  ))

  # The resolver only accepts file:// for the top-level manifest, so with a
  # core override the AIF manifest is flattened into one core manifest.
  flattened_yaml = var.core_platform_override == null ? "" : yamlencode({
    metadata = {
      name    = "${var.cluster_name}-core-platform"
      version = tostring(try(local.aif_manifest.metadata.version, "0.0.0"))
    }
    components = merge(
      {
        operatingSystem = { image = { base = var.core_platform_override.os_image_base, iso = var.core_platform_override.os_image_iso } }
        kubernetes      = { version = var.core_platform_override.kubernetes_version, image = var.core_platform_override.kubernetes_image }
      },
      { for k in ["systemd", "helm"] : k => local.rewritten_aif_components[k] if try(local.rewritten_aif_components[k], null) != null },
    )
  })

  sysext_only_yaml = yamlencode(merge(local.aif_manifest, { components = local.rewritten_aif_components }))

  release_manifest = (
    !local.rewrite_manifest ? local.manifest_body
    : var.core_platform_override != null ? local.flattened_yaml
    : local.sysext_only_yaml
  )
}

# Warns about override names no component maps to (likely typos). Names of
# known but disabled extensions stay silent: the default override is inert.
check "sysext_overrides_are_known" {
  assert {
    condition     = length(local.unmapped_sysext_overrides) == 0
    error_message = "sysext_image_overrides names extension(s) that no component uses and are ignored: ${join(", ", local.unmapped_sysext_overrides)}. Known extensions: ${join(", ", local.catalog_sysexts)}."
  }
}
