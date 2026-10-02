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


run "version_resolves_to_tag_url" {
  command = plan

  variables {
    aif_release = "2.3.0-dev.2"
  }

  assert {
    condition     = output.release_manifest_url == "https://raw.githubusercontent.com/SUSE/aif/refs/tags/aif-operator-2.3.0-dev.2/uc-release-manifest/release_manifest.yaml"
    error_message = "A version must resolve to the aif-operator-<version> tag manifest URL."
  }
}

run "default_release_is_a_version" {
  command = plan

  assert {
    condition     = strcontains(output.release_manifest_url, "/refs/tags/aif-operator-")
    error_message = "The default aif_release must resolve through a tag."
  }
}

run "url_is_used_verbatim" {
  command = plan

  variables {
    aif_release = "https://example.test/manifests/release_manifest.yaml"
  }

  assert {
    condition     = output.release_manifest_url == "https://example.test/manifests/release_manifest.yaml"
    error_message = "An http(s) aif_release must be used as the manifest URL unchanged."
  }
}

run "different_release_changes_url" {
  command = plan

  variables {
    aif_release = "https://example.test/other.yaml"
  }

  assert {
    condition     = output.release_manifest_url != run.default_release_is_a_version.release_manifest_url
    error_message = "A different aif_release must change the manifest URL."
  }
}

run "partial_version_rejected" {
  command = plan

  variables {
    aif_release = "2.2"
  }

  expect_failures = [var.aif_release]
}

run "pre_2_1_version_rejected" {
  command = plan

  variables {
    aif_release = "2.0.4"
  }

  expect_failures = [var.aif_release]
}

run "non_http_scheme_rejected" {
  command = plan

  variables {
    aif_release = "ftp://example.test/manifest.yaml"
  }

  expect_failures = [var.aif_release]
}
