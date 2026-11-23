mock_provider "http" {}

override_data {
  target = data.http.aif_release_manifest
  values = {
    status_code   = 200
    response_body = file("tests/fixtures/release_manifest.yaml")
  }
}

variables {
  cluster_name        = "test"
  api_vip             = "203.0.113.10"
  api_host            = "rke2-203.0.113.10.sslip.io"
  vpc_cidr            = "10.20.0.0/16"
  rke2_token          = "TOKEN"
  user_data_max_bytes = 786432
  kernel_cmdline      = "console=ttyS0 ignition.platform.id=test"
  nodes = [
    { hostname = "test-cp-01", type = "server", init = true },
    { hostname = "test-cp-02", type = "server" },
    { hostname = "test-cp-03", type = "server", node_ip = "10.20.0.7" },
    { hostname = "test-gpu-01", type = "agent" },
  ]
  root_password_hash         = "$6$SALT$ROOT"
  node_user_password_hash    = "$6$SALT$NODE"
  ssh_authorized_keys        = ["ssh-ed25519 AAAADUMMY test"]
  appco_username             = "appco-user"
  appco_password             = "appco-pass"
  suse_registry_username     = "REGCODE"
  suse_registry_password     = "regpass"
  nvidia_api_key             = "nvkey"
  rancher_hostname           = "rancher.example.test"
  rancher_bootstrap_password = "bootstrap"
}


run "disabled_leaves_manifest_verbatim" {
  command = plan

  assert {
    condition     = output.release_manifest == file("tests/fixtures/release_manifest.yaml")
    error_message = "Without the component and overrides the manifest must be shipped byte for byte."
  }
}

run "enabled_listed_in_release_yaml" {
  command = plan

  variables {
    components = ["cert-manager", "elemental-lifecycle-manager", "rancher"]
  }

  assert {
    condition     = strcontains(output.elemental_files["release.yaml"], "- chart: elemental-lifecycle-manager")
    error_message = "release.yaml must enable elemental-lifecycle-manager."
  }
}

run "flattened_with_rancher_adds_lcm_without_suc" {
  command = plan

  variables {
    components = ["rancher", "elemental-lifecycle-manager"]
    core_platform_override = {
      os_image_base      = "base:1"
      os_image_iso       = "iso:1"
      kubernetes_version = "v1"
      kubernetes_image   = "k8s:1"
    }
  }

  assert {
    condition = (
      [for c in yamldecode(output.release_manifest).components.helm.charts : c.chart if startswith(c.chart, "elemental-lifecycle-manager")]
      == ["elemental-lifecycle-manager-crds", "elemental-lifecycle-manager"]
      && alltrue([for c in yamldecode(output.release_manifest).components.helm.charts : c.version == "0.2.0" if startswith(c.chart, "elemental-lifecycle-manager")])
    )
    error_message = "Both Lifecycle Manager charts must be injected at 0.2.0."
  }

  assert {
    condition = (
      [for c in yamldecode(output.release_manifest).components.helm.charts : [for d in c.dependsOn : d.name] if c.chart == "elemental-lifecycle-manager"][0]
      == ["cert-manager", "elemental-lifecycle-manager-crds"]
    )
    error_message = "With Rancher the manager must depend on cert-manager and the CRDs only."
  }

  assert {
    condition     = !contains([for c in yamldecode(output.release_manifest).components.helm.charts : c.chart], "system-upgrade-controller")
    error_message = "System Upgrade Controller must not be added when Rancher is enabled."
  }

  assert {
    condition     = [for r in yamldecode(output.release_manifest).components.helm.repositories : r.name] == ["elemental-beta-charts"]
    error_message = "Only the beta chart repository must be added with Rancher."
  }

  assert {
    condition     = contains([for c in yamldecode(output.release_manifest).components.helm.charts : c.chart], "cert-manager")
    error_message = "The existing AIF charts must be kept."
  }
}

run "flattened_without_rancher_adds_suc" {
  command = plan

  variables {
    components = ["cert-manager", "elemental-lifecycle-manager"]
    core_platform_override = {
      os_image_base      = "base:1"
      os_image_iso       = "iso:1"
      kubernetes_version = "v1"
      kubernetes_image   = "k8s:1"
    }
  }

  assert {
    condition = (
      [for c in yamldecode(output.release_manifest).components.helm.charts : c.version if c.chart == "system-upgrade-controller"] == ["109.0.2"]
      && [for c in yamldecode(output.release_manifest).components.helm.charts : c.namespace if c.chart == "system-upgrade-controller"] == ["cattle-system"]
    )
    error_message = "System Upgrade Controller 109.0.2 in cattle-system must be added without Rancher."
  }

  assert {
    condition = (
      [for c in yamldecode(output.release_manifest).components.helm.charts : [for d in c.dependsOn : d.name] if c.chart == "elemental-lifecycle-manager"][0]
      == ["cert-manager", "elemental-lifecycle-manager-crds", "system-upgrade-controller"]
    )
    error_message = "Without Rancher the manager must also depend on System Upgrade Controller."
  }

  assert {
    condition     = [for r in yamldecode(output.release_manifest).components.helm.repositories : r.name] == ["elemental-beta-charts", "rancher-charts"]
    error_message = "The beta and Rancher chart repositories must be added without Rancher."
  }
}

run "core_platform_kept_without_core_override" {
  command = plan

  variables {
    components             = ["rancher", "elemental-lifecycle-manager"]
    core_platform_override = null
  }

  assert {
    condition     = yamldecode(output.release_manifest).corePlatform.image == "registry.suse.com/elemental/rke2/rke2-manifest:1.35.6-48.1"
    error_message = "corePlatform must be kept when no core override is set."
  }

  assert {
    condition     = output.release_manifest != file("tests/fixtures/release_manifest.yaml")
    error_message = "The manifest must be rewritten when the component is enabled."
  }

  assert {
    condition     = contains([for c in yamldecode(output.release_manifest).components.helm.charts : c.chart], "elemental-lifecycle-manager-crds")
    error_message = "The charts must be injected into the non-flattened manifest too."
  }
}

run "existing_chart_entry_replaced" {
  command = plan

  variables {
    components = ["rancher", "elemental-lifecycle-manager"]
  }

  override_data {
    target = data.http.aif_release_manifest
    values = {
      status_code   = 200
      response_body = <<-EOT
        metadata:
          name: x
          version: 2.4.0
        components:
          helm:
            charts:
              - chart: cert-manager
                version: v1
                namespace: cert-manager
                repository: jetstack
              - chart: elemental-lifecycle-manager
                version: "0.0.1"
                namespace: old
                repository: old
      EOT
    }
  }

  assert {
    condition     = length([for c in yamldecode(output.release_manifest).components.helm.charts : c if c.chart == "elemental-lifecycle-manager"]) == 1
    error_message = "A chart already in the manifest must be replaced, not duplicated."
  }

  assert {
    condition     = [for c in yamldecode(output.release_manifest).components.helm.charts : c.version if c.chart == "elemental-lifecycle-manager"] == ["0.2.0"]
    error_message = "The pinned version must replace the manifest entry."
  }
}

run "manifest_without_helm_section" {
  command = plan

  variables {
    components = ["rancher", "elemental-lifecycle-manager"]
  }

  override_data {
    target = data.http.aif_release_manifest
    values = {
      status_code   = 200
      response_body = "metadata:\n  name: x\n  version: 2.4.0\n"
    }
  }

  assert {
    condition     = length(yamldecode(output.release_manifest).components.helm.charts) == 2
    error_message = "A manifest without a helm section must still receive the charts."
  }
}

run "flatten_without_cert_manager_fails" {
  command = plan

  variables {
    components = ["rancher", "elemental-lifecycle-manager"]
    core_platform_override = {
      os_image_base      = "base:1"
      os_image_iso       = "iso:1"
      kubernetes_version = "v1"
      kubernetes_image   = "k8s:1"
    }
  }

  override_data {
    target = data.http.aif_release_manifest
    values = {
      status_code   = 200
      response_body = "metadata:\n  name: x\n  version: 2.4.0\n"
    }
  }

  expect_failures = [output.release_manifest]
}

run "baseline_hash" {
  command = plan

  variables {
    components = ["rancher"]
  }
}

run "component_changes_hash" {
  command = plan

  variables {
    components = ["rancher", "elemental-lifecycle-manager"]
  }

  assert {
    condition     = output.build_hash != run.baseline_hash.build_hash
    error_message = "Enabling elemental-lifecycle-manager must change build_hash."
  }
}
