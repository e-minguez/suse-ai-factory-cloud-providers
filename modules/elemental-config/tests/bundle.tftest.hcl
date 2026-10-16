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

run "bundle_covers_every_file" {
  command = plan

  assert {
    condition     = output.config_bundle == base64gzip(output.config_bundle_script)
    error_message = "config_bundle must be base64gzip of config_bundle_script."
  }

  assert {
    condition     = alltrue([for p in output.elemental_file_names : strcontains(output.config_bundle_script, "cat > \"$dir/${p}\" <<'__ELEMENTAL_CONFIG_EOF_7f3c__'\n")])
    error_message = "Every file needs a quoted-heredoc entry in the bundle."
  }

  assert {
    condition     = strcontains(output.config_bundle_script, "\"$dir/release_manifest.yaml\"") && startswith(output.config_bundle_script, "#!/bin/bash\n")
    error_message = "The bundle must include release_manifest.yaml and start with a shebang."
  }

  assert {
    condition     = strcontains(output.config_bundle_script, "chmod 0755 \"$dir/kubernetes/config/server.yaml\"") == false && strcontains(output.config_bundle_script, "chmod 0600 \"$dir/kubernetes/config/server.yaml\"")
    error_message = "Non-.sh files must be 0600."
  }
}

run "sh_files_are_executable" {
  command = plan

  variables {
    extra_config_files = { "hooks/run.sh" = "echo hi" }
  }

  assert {
    condition     = strcontains(output.config_bundle_script, "chmod 0755 \"$dir/hooks/run.sh\"\n") && strcontains(output.config_bundle_script, "echo hi\n__ELEMENTAL_CONFIG_EOF_7f3c__\n")
    error_message = ".sh files must be 0755 and gain a trailing newline."
  }
}

run "delimiter_line_rejected" {
  command = plan

  variables {
    extra_config_files = { "evil.yaml" = "a: b\n__ELEMENTAL_CONFIG_EOF_7f3c__\necho pwned\n" }
  }

  expect_failures = [output.config_bundle_script]
}

run "path_traversal_rejected" {
  command = plan

  variables {
    extra_config_files = { "../evil.yaml" = "a: b\n" }
  }

  expect_failures = [output.config_bundle_script]
}

run "unsafe_path_chars_rejected" {
  command = plan

  variables {
    extra_config_files = { "a b$(id).yaml" = "a: b\n" }
  }

  expect_failures = [output.config_bundle_script]
}
