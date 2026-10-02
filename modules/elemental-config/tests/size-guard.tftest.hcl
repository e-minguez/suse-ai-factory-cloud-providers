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

run "within_limit" {
  command = plan
}

run "over_limit_fails" {
  command = plan

  variables {
    user_data_max_bytes = 200
  }

  expect_failures = [output.node_runtime_ignition]
}

run "gzip_shrinks_node_files" {
  command = plan

  variables {
    compress_node_files = true
  }

  assert {
    condition     = jsondecode(output.node_runtime_ignition["test-cp-01"]).storage.files[0].contents.compression == "gzip"
    error_message = "compress_node_files must set compression = gzip."
  }

  assert {
    condition     = length(output.node_runtime_ignition["test-cp-01"]) < length(run.within_limit.node_runtime_ignition["test-cp-01"]) + 200
    error_message = "gzip must not blow up the payload."
  }
}

run "duplicate_hostnames_rejected" {
  command = plan

  variables {
    nodes = [
      { hostname = "a", type = "server", init = true },
      { hostname = "a", type = "agent" },
    ]
  }

  expect_failures = [var.nodes]
}
