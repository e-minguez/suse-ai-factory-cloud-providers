# Plan-only checks with mocked rancher2 providers; no Rancher is contacted.

mock_provider "rancher2" {
  override_resource {
    target = rancher2_cluster.downstream
    values = {
      id = "c-m-test"
      cluster_registration_token = [{
        manifest_url = "https://rancher.example/v3/import/tok_c-m-test.yaml"
      }]
    }
  }
}

mock_provider "rancher2" {
  alias = "bootstrap"
}

variables {
  mgmt = {
    cluster_name = "mgmt"
    rancher_url  = "https://rancher.example"
  }
  rancher_token = "token-x:secret"
  downstream = {
    gpu-a = { cluster_name = "gpu-a", provider = "aws", egress_ips = ["198.51.100.4"] }
    gpu-b = { cluster_name = "gpu-b", provider = "vultr", egress_ips = [] }
  }
}

run "imports_each_downstream" {
  command = apply

  assert {
    condition     = length(rancher2_cluster.downstream) == 2
    error_message = "expected one rancher2_cluster per downstream"
  }

  assert {
    condition     = rancher2_cluster.downstream["gpu-a"].name == "gpu-a"
    error_message = "cluster name must come from the cluster_name output"
  }

  assert {
    condition     = length(rancher2_bootstrap.admin) == 0
    error_message = "bootstrap must be off by default"
  }

  assert {
    condition     = output.cluster_ids["gpu-b"] == "c-m-test"
    error_message = "cluster_ids must map directory to Rancher ID"
  }
}

run "no_downstream_is_empty_plan" {
  command = plan

  variables {
    downstream = {}
  }

  assert {
    condition     = length(rancher2_cluster.downstream) == 0
    error_message = "empty downstream must create nothing"
  }
}

run "bootstrap_needs_password" {
  command = plan

  variables {
    bootstrap = true
  }

  expect_failures = [rancher2_bootstrap.admin]
}

run "bootstrap_with_password" {
  command = plan

  variables {
    bootstrap          = true
    bootstrap_password = "first-login"
  }

  assert {
    condition     = length(rancher2_bootstrap.admin) == 1
    error_message = "bootstrap = true must create rancher2_bootstrap"
  }
}

run "rejects_http_rancher_url" {
  command = plan

  variables {
    mgmt = {
      cluster_name = "mgmt"
      rancher_url  = "http://rancher.example"
    }
  }

  expect_failures = [var.mgmt]
}

run "rejects_bad_cluster_name" {
  command = plan

  variables {
    downstream = {
      x = { cluster_name = "Bad_Name", provider = "aws", egress_ips = [] }
    }
  }

  expect_failures = [var.downstream]
}

run "admin_password_null_without_bootstrap" {
  command = plan

  assert {
    condition     = output.admin_password == null
    error_message = "admin_password must be null without bootstrap"
  }
}
