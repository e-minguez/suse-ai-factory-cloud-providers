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

run "no_override_ships_manifest_verbatim" {
  command = plan

  assert {
    condition     = output.release_manifest == file("tests/fixtures/release_manifest.yaml")
    error_message = "Without overrides the manifest must be shipped byte for byte."
  }

  assert {
    condition     = output.elemental_files["release_manifest.yaml"] == output.release_manifest
    error_message = "release_manifest.yaml in elemental_files must equal the release_manifest output."
  }
}

run "core_override_flattens_manifest" {
  command = plan

  variables {
    core_platform_override = {
      os_image_base      = "base:1"
      os_image_iso       = "iso:1"
      kubernetes_version = "v1"
      kubernetes_image   = "k8s:1"
    }
  }

  assert {
    condition     = yamldecode(output.release_manifest).metadata.name == "test-core-platform"
    error_message = "The flattened manifest must be named after the cluster."
  }

  assert {
    condition     = yamldecode(output.release_manifest).metadata.version == "2.3.0"
    error_message = "The flattened manifest must reuse the AIF manifest version."
  }

  assert {
    condition = (
      yamldecode(output.release_manifest).components.operatingSystem.image.iso == "iso:1"
      && yamldecode(output.release_manifest).components.kubernetes.image == "k8s:1"
    )
    error_message = "The flattened manifest must pin the override images."
  }

  assert {
    condition     = !can(yamldecode(output.release_manifest).corePlatform)
    error_message = "The flattened manifest must drop corePlatform."
  }

  assert {
    condition     = length(yamldecode(output.release_manifest).components.helm.charts) == 2 && length(yamldecode(output.release_manifest).components.systemd.extensions) == 1
    error_message = "The flattened manifest must keep helm charts and systemd extensions."
  }

  assert {
    condition     = yamldecode(output.release_manifest).components.helm.charts[1].values.global.psp.enabled == "false"
    error_message = "String values must survive the rewrite as strings."
  }
}

run "sysext_override_rewrites_image_only" {
  command = plan

  variables {
    components             = ["rancher", "suse-storage", "aif-operator"]
    sysext_image_overrides = { suse-storage = "registry.example.test/longhorn:1" }
  }

  assert {
    condition     = yamldecode(output.release_manifest).components.systemd.extensions[0].image == "registry.example.test/longhorn:1"
    error_message = "The sysext image must be overridden."
  }

  assert {
    condition     = yamldecode(output.release_manifest).corePlatform.image == "registry.suse.com/elemental/rke2/rke2-manifest:1.35.6-48.1"
    error_message = "Without a core override the manifest chain must stay intact."
  }
}

run "core_and_sysext_overrides_combine" {
  command = plan

  variables {
    components             = ["rancher", "suse-storage", "aif-operator"]
    sysext_image_overrides = { suse-storage = "registry.example.test/longhorn:1" }
    core_platform_override = {
      os_image_base      = "base:1"
      os_image_iso       = "iso:1"
      kubernetes_version = "v1"
      kubernetes_image   = "k8s:1"
    }
  }

  assert {
    condition     = yamldecode(output.release_manifest).components.systemd.extensions[0].image == "registry.example.test/longhorn:1"
    error_message = "The flattened manifest must carry the overridden sysext image."
  }
}

run "unknown_sysext_override_fails" {
  command = plan

  override_data {
    target = data.http.aif_release_manifest
    values = {
      status_code   = 200
      response_body = file("tests/fixtures/release_manifest_no_sysext.yaml")
    }
  }

  variables {
    components             = ["rancher", "suse-storage", "aif-operator"]
    sysext_image_overrides = { suse-storage = "registry.example.test/longhorn:1" }
  }

  expect_failures = [output.release_manifest]
}

run "core_override_rejects_ga_os_image" {
  command = plan

  variables {
    core_platform_override = {
      os_image_base      = "registry.suse.com/elemental/base-os-kernel-default:1"
      os_image_iso       = "registry.suse.com/elemental/base-os-kernel-default-iso:1"
      kubernetes_version = "v1"
      kubernetes_image   = "k8s:1"
    }
  }

  expect_failures = [var.core_platform_override]
}

run "misspelled_sysext_override_warns" {
  command = plan

  variables {
    sysext_image_overrides = { suse-storge = "registry.example.test/longhorn:1" }
  }

  expect_failures = [check.sysext_overrides_are_known]
}
