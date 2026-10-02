# Which optional credential sets were supplied ("" counts as unset). Plain
# booleans, so templates can branch on them without touching the secrets.
locals {
  appco_set         = nonsensitive(try(trimspace(var.appco_username) != "" && trimspace(var.appco_password) != "", false))
  suse_registry_set = nonsensitive(try(trimspace(var.suse_registry_username) != "" && trimspace(var.suse_registry_password) != "", false))
  nvidia_set        = nonsensitive(try(trimspace(var.nvidia_api_key) != "", false))

  # Image pull Secret data for local-path-provisioner; null without appco.
  dockerconfigjson_b64 = !local.appco_set ? null : base64encode(jsonencode({
    auths = {
      (var.appco_registry) = {
        username = var.appco_username
        password = var.appco_password
        auth     = base64encode("${var.appco_username}:${var.appco_password}")
      }
    }
  }))
}

resource "random_password" "rancher_bootstrap" {
  length  = 24
  special = false
}

locals {
  # Conditional, not coalesce(): the generated value is unknown at plan time and
  # must not make the render unknown when the input is set.
  rancher_bootstrap_password = var.rancher_bootstrap_password != null ? var.rancher_bootstrap_password : random_password.rancher_bootstrap.result

  # The single ordered component list. Order is canonical, never the order of
  # var.components, so reordering it cannot change the image.
  #   values_template   file under templates/elemental/kubernetes/helm/values, or null
  #   chart_credentials release.yaml carries Application Collection chart-pull auth
  #   pull_secret_ns    namespace that gets an image pull Secret, or null
  #   sysext            systemd extension the chart needs, or null
  component_catalog = [
    {
      name              = "cert-manager"
      values_template   = null
      values_vars       = {}
      chart_credentials = false
      pull_secret_ns    = null
      sysext            = null
    },
    {
      name              = "rancher"
      values_template   = "rancher.yaml.tftpl"
      values_vars       = { hostname = var.rancher_hostname, bootstrap_password = local.rancher_bootstrap_password }
      chart_credentials = false
      pull_secret_ns    = null
      sysext            = null
    },
    {
      name              = "gpu-operator"
      values_template   = "gpu-operator.yaml.tftpl"
      values_vars       = { repository = var.gpu_driver_repository, version = var.gpu_driver_version }
      chart_credentials = false
      pull_secret_ns    = null
      sysext            = null
    },
    {
      name              = "local-path-provisioner"
      values_template   = "local-path-provisioner.yaml.tftpl"
      values_vars       = {}
      chart_credentials = true
      pull_secret_ns    = "local-path-provisioner"
      sysext            = null
    },
    {
      name              = "suse-storage"
      values_template   = "suse-storage.yaml.tftpl"
      values_vars       = { appco_username = var.appco_username, appco_password = var.appco_password }
      chart_credentials = true
      pull_secret_ns    = null
      sysext            = "suse-storage"
    },
    {
      name            = "aif-operator"
      values_template = "aif-operator.yaml.tftpl"
      values_vars = {
        appco_username         = var.appco_username
        appco_password         = var.appco_password
        suse_registry_username = var.suse_registry_username
        suse_registry_password = var.suse_registry_password
        nvidia_api_key         = var.nvidia_api_key
        nvidia_username        = var.nvidia_username
        appco_set              = local.appco_set
        suse_registry_set      = local.suse_registry_set
        nvidia_set             = local.nvidia_set
      }
      chart_credentials = false
      pull_secret_ns    = null
      sysext            = null
    },
  ]

  enabled_specs      = [for c in local.component_catalog : c if contains(var.components, c.name)]
  enabled_components = [for c in local.enabled_specs : c.name]
  enabled_sysexts    = distinct([for c in local.enabled_specs : c.sysext if c.sysext != null])

  component_values_files = {
    for c in local.enabled_specs :
    "kubernetes/helm/values/${c.name}.yaml" => templatefile(
      "${path.module}/templates/elemental/kubernetes/helm/values/${c.values_template}", c.values_vars
    ) if c.values_template != null
  }

  component_pull_secret_manifests = {
    for c in local.enabled_specs :
    "kubernetes/manifests/${c.name}.yaml" => templatefile(
      "${path.module}/templates/elemental/kubernetes/manifests/appco-pull-secret.yaml.tftpl",
      { namespace = c.pull_secret_ns, dockerconfigjson_b64 = local.dockerconfigjson_b64 }
    ) if c.pull_secret_ns != null
  }
}

locals {
  catalog_sysexts           = distinct([for c in local.component_catalog : c.sysext if c.sysext != null])
  unmapped_sysext_overrides = sort(setsubtract(toset(keys(var.sysext_image_overrides)), toset(local.catalog_sysexts)))
}

# Warning only: aif-operator deploys without these, but cannot pull its
# workloads until they are added.
check "aif_operator_credentials" {
  assert {
    condition = !contains(var.components, "aif-operator") || (local.appco_set && local.suse_registry_set && local.nvidia_set)
    error_message = "aif-operator is enabled without ${join(", ", compact([
      local.appco_set ? "" : "appco_username/appco_password",
      local.suse_registry_set ? "" : "suse_registry_username/suse_registry_password",
      local.nvidia_set ? "" : "nvidia_api_key",
    ]))}. Set them so AI Factory is ready to use after the deployment."
  }
}
