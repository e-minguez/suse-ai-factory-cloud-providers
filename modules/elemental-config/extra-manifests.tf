locals {
  # Relative paths resolve against the root module (clusters/<name>/ under cluster.sh).
  extra_manifests_path = var.extra_manifests_dir == null ? null : (
    startswith(pathexpand(var.extra_manifests_dir), "/") ? pathexpand(var.extra_manifests_dir) : "${path.root}/${var.extra_manifests_dir}"
  )

  # No direxists(): fileexists() errors on a directory and returns false for a missing path.
  extra_manifests_dir_ok = local.extra_manifests_path == null || !can(fileexists(local.extra_manifests_path))

  # Top level only; other extensions are ignored.
  extra_manifest_sources = local.extra_manifests_path == null || !local.extra_manifests_dir_ok ? [] : sort(tolist(
    fileset(local.extra_manifests_path, "*.{yaml,yml}")
  ))

  extra_manifest_bad_names = [
    for f in local.extra_manifest_sources : f if !can(regex("^[A-Za-z0-9._-]+$", f))
  ]

  # foo.yml -> extra-foo.yaml; a -priority suffix survives, so elemental applies
  # the file before its HelmCharts (docs/decisions/001-elemental-config-rationale.md).
  extra_manifest_targets = {
    for f in local.extra_manifest_sources :
    f => "kubernetes/manifests/extra-${replace(f, "/\\.ya?ml$/", "")}.yaml"
    if !contains(local.extra_manifest_bad_names, f)
  }

  # foo.yaml and foo.yml map to one target; grouped so the precondition, not a
  # duplicate-key error, reports it.
  extra_manifest_groups = { for f, t in local.extra_manifest_targets : t => f... }

  extra_manifest_duplicates = [
    for target, sources in local.extra_manifest_groups :
    "${join(" and ", sources)} (both ${target})" if length(sources) > 1
  ]

  # Shipped as-is (no comment strip: it can break block scalars). May hold
  # registration tokens, so sensitive like the rest of elemental_files.
  extra_manifest_files = {
    for target, sources in local.extra_manifest_groups :
    target => sensitive(file("${local.extra_manifests_path}/${sources[0]}"))
  }
}
