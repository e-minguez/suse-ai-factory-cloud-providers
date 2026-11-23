# Elemental Lifecycle Manager charts, injected into the release manifest when
# the elemental-lifecycle-manager component is enabled (see beta-overrides.tf).
# Pins live here only: bump them in this block.
locals {
  lcm_enabled      = contains(var.components, "elemental-lifecycle-manager")
  lcm_with_rancher = contains(var.components, "rancher")

  lcm_chart_version = "0.2.0"
  lcm_repository    = { name = "elemental-beta-charts", url = "oci://registry.suse.com/beta/uc/charts" }

  # Rancher installs System Upgrade Controller itself; add it only without Rancher.
  suc_chart_version = "109.0.2"
  suc_repository    = { name = "rancher-charts", url = "https://charts.rancher.io/" }

  lcm_charts = concat(
    [
      {
        chart      = "elemental-lifecycle-manager-crds"
        version    = local.lcm_chart_version
        namespace  = "elemental-system"
        repository = local.lcm_repository.name
      },
      {
        chart      = "elemental-lifecycle-manager"
        version    = local.lcm_chart_version
        namespace  = "elemental-system"
        repository = local.lcm_repository.name
        dependsOn = [for d in concat(
          ["cert-manager", "elemental-lifecycle-manager-crds"],
          local.lcm_with_rancher ? [] : ["system-upgrade-controller"],
        ) : { name = d, type = "helm" }]
      },
    ],
    local.lcm_with_rancher ? [] : [
      {
        chart      = "system-upgrade-controller"
        version    = local.suc_chart_version
        namespace  = "cattle-system"
        repository = local.suc_repository.name
      },
    ],
  )

  lcm_repositories = concat([local.lcm_repository], local.lcm_with_rancher ? [] : [local.suc_repository])

  # Entries already in the AIF manifest with the same chart or repository name
  # are replaced, so these pins win when the manifest is flattened.
  aif_helm   = try(local.aif_components.helm, {})
  aif_charts = try(local.aif_helm.charts, [])
  aif_repos  = try(local.aif_helm.repositories, [])

  # jsondecode(string) keeps both branches the same type.
  lcm_merged_charts = jsondecode(local.lcm_enabled ? jsonencode(concat(
    [for c in local.aif_charts : c if !contains([for n in local.lcm_charts : n.chart], c.chart)], local.lcm_charts
  )) : jsonencode(local.aif_charts))

  lcm_merged_repos = jsondecode(local.lcm_enabled ? jsonencode(concat(
    [for r in local.aif_repos : r if !contains([for n in local.lcm_repositories : n.name], r.name)], local.lcm_repositories
  )) : jsonencode(local.aif_repos))

  # The helm section to merge into the manifest components; empty when disabled.
  lcm_helm_section = {
    for k, v in { helm = merge(local.aif_helm, { charts = local.lcm_merged_charts, repositories = local.lcm_merged_repos }) } : k => v
    if local.lcm_enabled
  }

  # Without a core override the core platform manifest resolves cert-manager;
  # a flattened manifest has no core platform, so the AIF manifest must list it.
  lcm_cert_manager_ok = !local.lcm_enabled || var.core_platform_override == null || contains([for c in local.aif_charts : c.chart], "cert-manager")
}
