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

run "baseline" {
  command = plan
}

run "core_platform_override_changes_hash" {
  command = plan

  variables {
    core_platform_override = {
      os_image_base      = "registry.suse.com/beta/uc/base-os-kernel-default:16.1-1"
      os_image_iso       = "registry.suse.com/beta/uc/base-os-kernel-default-iso:16.1-1"
      kubernetes_version = "v1.35.6+rke2r1"
      kubernetes_image   = "registry.suse.com/elemental/rke2/rke2-tar:1.35.6_rke2r1-9.1"
    }
  }

  assert {
    condition     = output.build_hash != run.baseline.build_hash
    error_message = "Setting core_platform_override must change build_hash."
  }
}

run "core_platform_override_value_changes_hash" {
  command = plan

  variables {
    core_platform_override = {
      os_image_base      = "registry.suse.com/beta/uc/base-os-kernel-default:16.1-2"
      os_image_iso       = "registry.suse.com/beta/uc/base-os-kernel-default-iso:16.1-2"
      kubernetes_version = "v1.35.6+rke2r1"
      kubernetes_image   = "registry.suse.com/elemental/rke2/rke2-tar:1.35.6_rke2r1-9.1"
    }
  }

  assert {
    condition     = output.build_hash != run.core_platform_override_changes_hash.build_hash
    error_message = "Changing core_platform_override must change build_hash."
  }
}

run "elemental_image_changes_hash" {
  command = plan

  variables {
    elemental_image = "registry.suse.com/beta/uc/elemental:other"
  }

  assert {
    condition     = output.build_hash != run.baseline.build_hash
    error_message = "Changing elemental_image must change build_hash."
  }
}

run "sysext_override_changes_hash_only_when_enabled" {
  command = plan

  variables {
    sysext_image_overrides = { suse-storage = "registry.example.test/longhorn:1" }
  }

  assert {
    condition     = output.build_hash == run.baseline.build_hash && output.effective_sysext_overrides == {}
    error_message = "An override for an extension no component needs must be inert."
  }
}

run "sysext_override_changes_hash_when_enabled" {
  command = plan

  variables {
    components             = ["rancher", "suse-storage", "aif-operator"]
    sysext_image_overrides = { suse-storage = "registry.example.test/longhorn:1" }
  }

  assert {
    condition     = output.effective_sysext_overrides == { suse-storage = "registry.example.test/longhorn:1" }
    error_message = "An override for an enabled extension must be effective."
  }
}

run "sysext_override_value_changes_hash" {
  command = plan

  variables {
    components             = ["rancher", "suse-storage", "aif-operator"]
    sysext_image_overrides = { suse-storage = "registry.example.test/longhorn:2" }
  }

  assert {
    condition     = output.build_hash != run.sysext_override_changes_hash_when_enabled.build_hash
    error_message = "Changing an effective sysext override must change build_hash."
  }
}

run "stable_across_plans" {
  command = plan

  assert {
    condition     = output.build_hash == run.baseline.build_hash
    error_message = "build_hash must be stable across plans of the same inputs."
  }
}

run "extra_build_inputs_change_hash" {
  command = plan

  variables {
    extra_build_inputs = { factory_script = "abc" }
  }

  assert {
    condition     = output.build_hash != run.baseline.build_hash
    error_message = "extra_build_inputs must feed build_hash."
  }
}

run "credentials_change_hash" {
  command = plan

  variables {
    nvidia_api_key = "another"
  }

  assert {
    condition     = output.build_hash != run.baseline.build_hash
    error_message = "Rendered credentials must feed build_hash."
  }
}

run "node_set_change_keeps_hash" {
  command = plan

  variables {
    nodes = [
      { hostname = "test-cp-01", type = "server", init = true },
      { hostname = "test-cp-02", type = "server" },
      { hostname = "test-cp-03", type = "server" },
      { hostname = "test-gpu-01", type = "agent" },
      { hostname = "test-gpu-02", type = "agent" },
    ]
  }

  assert {
    condition     = output.build_hash == run.baseline.build_hash
    error_message = "Adding a GPU node must not change build_hash."
  }
}

run "rebuild_zero_keeps_hash" {
  command = plan

  variables {
    image_rebuild = 0
  }

  assert {
    condition     = output.build_hash == run.baseline.build_hash
    error_message = "image_rebuild = 0 must not change build_hash."
  }
}

run "rebuild_counter_changes_hash" {
  command = plan

  variables {
    image_rebuild = 1
  }

  assert {
    condition     = output.build_hash != run.baseline.build_hash
    error_message = "Bumping image_rebuild must change build_hash."
  }
}

run "rebuild_counter_values_differ" {
  command = plan

  variables {
    image_rebuild = 2
  }

  assert {
    condition     = output.build_hash != run.rebuild_counter_changes_hash.build_hash
    error_message = "Each image_rebuild value must give its own build_hash."
  }
}
