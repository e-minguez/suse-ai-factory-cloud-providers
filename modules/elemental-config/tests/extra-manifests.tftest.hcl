# extra_manifests_dir: files land in kubernetes/manifests/ with an extra- prefix,
# unchanged (no comment strip), and feed build_hash. Relative paths resolve
# against path.root, the module directory under terraform test.

mock_provider "http" {}

override_data {
  target = data.http.aif_release_manifest
  values = {
    status_code   = 200
    response_body = file("tests/fixtures/release_manifest.yaml")
  }
}

variables {
  cluster_name               = "test"
  api_vip                    = "203.0.113.10"
  api_host                   = "rke2-203.0.113.10.sslip.io"
  vpc_cidr                   = "10.20.0.0/16"
  rke2_token                 = "TOKEN"
  user_data_max_bytes        = 786432
  kernel_cmdline             = "console=ttyS0 ignition.platform.id=test"
  root_password_hash         = "$6$SALT$ROOT"
  node_user_password_hash    = "$6$SALT$NODE"
  ssh_authorized_keys        = ["ssh-ed25519 AAAADUMMY test"]
  rancher_hostname           = "rancher.example.test"
  appco_username             = "u"
  appco_password             = "p"
  suse_registry_username     = "u"
  suse_registry_password     = "p"
  nvidia_api_key             = "k"
  rancher_bootstrap_password = "bootstrap"
  nodes = [
    { hostname = "test-cp-01", type = "server", init = true },
  ]
}

run "unset" {
  command = plan

  assert {
    condition     = length([for p in output.elemental_file_names : p if startswith(p, "kubernetes/manifests/extra-")]) == 0
    error_message = "No extra manifests without extra_manifests_dir."
  }
}

run "two_files" {
  command = plan

  variables {
    extra_manifests_dir = "tests/fixtures/extra-manifests/two"
  }

  assert {
    condition = (
      contains(output.elemental_file_names, "kubernetes/manifests/extra-registration.yaml") &&
      contains(output.elemental_file_names, "kubernetes/manifests/extra-settings.yaml") &&
      length([for p in output.elemental_file_names : p if startswith(p, "kubernetes/manifests/extra-")]) == 2
    )
    error_message = "Both manifests must be added as extra-<basename>.yaml (.yml renamed): ${join(", ", output.elemental_file_names)}."
  }

  assert {
    condition     = nonsensitive(output.elemental_files["kubernetes/manifests/extra-registration.yaml"]) == file("tests/fixtures/extra-manifests/two/registration.yaml")
    error_message = "Extra manifests must ship unchanged, comment lines included."
  }

  assert {
    condition     = strcontains(nonsensitive(output.elemental_files["kubernetes/manifests/extra-registration.yaml"]), "# Applied once at first boot; this comment must survive.\n")
    error_message = "The # comment line must not be stripped."
  }

  assert {
    condition     = output.build_hash != run.unset.build_hash
    error_message = "Extra manifests must feed build_hash."
  }

  assert {
    condition     = output.node_runtime_ignition == run.unset.node_runtime_ignition
    error_message = "Extra manifests go into the image only, never into per-node Ignition."
  }

  assert {
    condition     = strcontains(nonsensitive(output.config_bundle_script), "\"$dir/kubernetes/manifests/extra-registration.yaml\"")
    error_message = "Extra manifests must be in the config bundle."
  }
}

run "changed_content_changes_hash" {
  command = plan

  variables {
    extra_manifests_dir = "tests/fixtures/extra-manifests/changed"
  }

  assert {
    condition     = output.build_hash != run.two_files.build_hash
    error_message = "A changed manifest must change build_hash."
  }
}

run "absolute_path" {
  command = plan

  variables {
    extra_manifests_dir = abspath("tests/fixtures/extra-manifests/two")
  }

  assert {
    condition     = output.build_hash == run.two_files.build_hash
    error_message = "An absolute path to the same directory must give the same build_hash."
  }
}

run "priority_suffix_and_non_yaml_ignored" {
  command = plan

  variables {
    extra_manifests_dir = "tests/fixtures/extra-manifests/priority"
  }

  assert {
    condition = (
      contains(output.elemental_file_names, "kubernetes/manifests/extra-namespace-priority.yaml") &&
      length([for p in output.elemental_file_names : p if startswith(p, "kubernetes/manifests/extra-")]) == 1
    )
    error_message = "Expected only extra-namespace-priority.yaml (README.txt and values.json ignored): ${join(", ", output.elemental_file_names)}."
  }
}

run "no_yaml_files" {
  command = plan

  variables {
    extra_manifests_dir = "tests/fixtures/extra-manifests/empty"
  }

  assert {
    condition     = output.build_hash == run.unset.build_hash
    error_message = "A directory without manifests must leave build_hash unchanged."
  }
}

run "missing_dir_fails" {
  command = plan

  variables {
    extra_manifests_dir = "tests/fixtures/extra-manifests/does-not-exist"
  }

  expect_failures = [output.build_hash]
}

run "file_instead_of_dir_fails" {
  command = plan

  variables {
    extra_manifests_dir = "tests/fixtures/extra-manifests/two/settings.yml"
  }

  expect_failures = [output.build_hash]
}

run "empty_string_fails" {
  command = plan

  variables {
    extra_manifests_dir = ""
  }

  expect_failures = [var.extra_manifests_dir]
}

run "bad_name_fails" {
  command = plan

  variables {
    extra_manifests_dir = "tests/fixtures/extra-manifests/bad-name"
  }

  expect_failures = [output.build_hash]
}

run "yaml_and_yml_collision_fails" {
  command = plan

  variables {
    extra_manifests_dir = "tests/fixtures/extra-manifests/duplicate"
  }

  expect_failures = [output.build_hash]
}
