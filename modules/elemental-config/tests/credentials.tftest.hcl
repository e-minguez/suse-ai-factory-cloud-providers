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

run "special_characters_round_trip" {
  command = plan

  variables {
    appco_username             = "us\"er:#1"
    appco_password             = "p\"a\\ss#: {x} 'q' *&!"
    suse_registry_username     = "R\"C\\#:"
    suse_registry_password     = "\\\"#: end "
    nvidia_api_key             = "nv\"\\#:key"
    rancher_bootstrap_password = "b\"\\#: [x]"
    components                 = ["rancher", "gpu-operator", "suse-storage", "aif-operator"]
  }

  assert {
    condition     = yamldecode(output.elemental_files["kubernetes/helm/values/rancher.yaml"]).bootstrapPassword == var.rancher_bootstrap_password
    error_message = "rancher.yaml bootstrapPassword must round-trip."
  }

  assert {
    condition = (
      yamldecode(output.elemental_files["kubernetes/helm/values/aif-operator.yaml"]).credentials.applicationCollection.username == var.appco_username
      && yamldecode(output.elemental_files["kubernetes/helm/values/aif-operator.yaml"]).credentials.applicationCollection.password == var.appco_password
      && yamldecode(output.elemental_files["kubernetes/helm/values/aif-operator.yaml"]).credentials.suseRegistry.username == var.suse_registry_username
      && yamldecode(output.elemental_files["kubernetes/helm/values/aif-operator.yaml"]).credentials.suseRegistry.password == var.suse_registry_password
      && yamldecode(output.elemental_files["kubernetes/helm/values/aif-operator.yaml"]).credentials.nvidia.password == var.nvidia_api_key
    )
    error_message = "aif-operator.yaml credentials must round-trip."
  }

  assert {
    condition = (
      yamldecode(output.elemental_files["kubernetes/helm/values/suse-storage.yaml"]).privateRegistry.registryUser == var.appco_username
      && yamldecode(output.elemental_files["kubernetes/helm/values/suse-storage.yaml"]).privateRegistry.registryPasswd == var.appco_password
    )
    error_message = "suse-storage.yaml registry credentials must round-trip."
  }

  assert {
    condition = alltrue([
      for c in yamldecode(output.elemental_files["release.yaml"]).components.helm :
      c.credentials.password == var.appco_password && c.credentials.username == var.appco_username
      if contains(["suse-storage"], c.chart)
    ])
    error_message = "release.yaml chart credentials must round-trip."
  }

  assert {
    condition     = jsondecode(base64decode(output.dockerconfigjson_b64)).auths["dp.apps.rancher.io"].password == var.appco_password
    error_message = "dockerconfigjson must carry the appco password."
  }

  assert {
    condition     = output.rancher_bootstrap_password == var.rancher_bootstrap_password
    error_message = "rancher_bootstrap_password output must echo the input when set."
  }
}

run "optional_credentials_are_omitted" {
  command = plan

  variables {
    components             = ["rancher", "gpu-operator", "aif-operator"]
    appco_username         = null
    appco_password         = null
    suse_registry_username = null
    suse_registry_password = null
    nvidia_api_key         = ""
  }

  assert {
    condition     = trimspace(output.elemental_files["kubernetes/helm/values/aif-operator.yaml"]) == ""
    error_message = "aif-operator.yaml must carry no credentials block when none are set."
  }

  assert {
    condition     = output.dockerconfigjson_b64 == null
    error_message = "dockerconfigjson_b64 must be null without appco credentials."
  }

  # aif-operator without credentials: the plan warns, it does not fail.
  expect_failures = [check.aif_operator_credentials]
}

run "nvidia_username_is_configurable" {
  command = plan

  variables {
    nvidia_username = "custom"
  }

  assert {
    condition     = yamldecode(output.elemental_files["kubernetes/helm/values/aif-operator.yaml"]).credentials.nvidia.username == "custom"
    error_message = "nvidia_username must reach aif-operator.yaml."
  }
}

run "nvidia_username_defaults_to_oauthtoken" {
  command = plan

  assert {
    condition     = yamldecode(output.elemental_files["kubernetes/helm/values/aif-operator.yaml"]).credentials.nvidia.username == "$oauthtoken"
    error_message = "nvidia_username must default to $oauthtoken."
  }
}

run "appco_required_for_storage_charts" {
  command = plan

  variables {
    components     = ["local-path-provisioner"]
    appco_username = null
    appco_password = null
  }

  expect_failures = [var.appco_username]
}

run "appco_pair_must_be_complete" {
  command = plan

  variables {
    appco_password = null
  }

  expect_failures = [var.appco_username]
}
