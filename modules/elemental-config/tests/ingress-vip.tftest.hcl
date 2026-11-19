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

run "vip_null_adds_nothing" {
  command = plan

  variables {
    api_vip_mode = "managed"
  }

  assert {
    condition = alltrue([
      !contains(output.elemental_file_names, "kubernetes/manifests/ingress-vip.yaml"),
      !contains(output.elemental_file_names, "kubernetes/manifests/ingress-nginx-priority.yaml"),
      strcontains(output.elemental_files["kubernetes/manifests/traefik-priority.yaml"], "proxyProtocol"),
      !strcontains(output.elemental_files["kubernetes/manifests/traefik-priority.yaml"], "LoadBalancer"),
    ])
    error_message = "ingress_vip null must not render any VIP manifest or change the traefik config."
  }
}

run "vip_traefik" {
  command = plan

  variables {
    api_vip_mode = "managed"
    ingress_vip  = "10.20.0.41"
  }

  assert {
    condition = alltrue([
      strcontains(output.elemental_files["kubernetes/manifests/ingress-vip.yaml"], "- 10.20.0.41/32"),
      strcontains(output.elemental_files["kubernetes/manifests/ingress-vip.yaml"], "avoidBuggyIPs: true"),
      strcontains(output.elemental_files["kubernetes/manifests/ingress-vip.yaml"], "values: [rke2-traefik, traefik]"),
      strcontains(output.elemental_files["kubernetes/manifests/ingress-vip.yaml"], "kind: L2Advertisement"),
      strcontains(output.elemental_files["kubernetes/manifests/traefik-priority.yaml"], "type: LoadBalancer"),
      strcontains(output.elemental_files["kubernetes/manifests/traefik-priority.yaml"], "externalTrafficPolicy: Local"),
      strcontains(output.elemental_files["kubernetes/manifests/traefik-priority.yaml"], "hostPort: 8080"),
      !strcontains(output.elemental_files["kubernetes/manifests/traefik-priority.yaml"], "proxyProtocol"),
      !contains(output.elemental_file_names, "kubernetes/manifests/ingress-nginx-priority.yaml"),
      output.build_hash != run.baseline.build_hash,
    ])
    error_message = "ingress_vip with traefik must render the pool, L2 advertisement and LoadBalancer config, and change build_hash."
  }
}

run "vip_nginx" {
  command = plan

  variables {
    api_vip_mode       = "managed"
    ingress_vip        = "10.20.0.41"
    ingress_controller = "ingress-nginx"
  }

  assert {
    condition = alltrue([
      strcontains(output.elemental_files["kubernetes/manifests/ingress-vip.yaml"], "- 10.20.0.41/32"),
      strcontains(output.elemental_files["kubernetes/manifests/ingress-vip.yaml"], "values: [rke2-ingress-nginx, ingress-nginx]"),
      strcontains(output.elemental_files["kubernetes/manifests/ingress-nginx-priority.yaml"], "name: rke2-ingress-nginx"),
      strcontains(output.elemental_files["kubernetes/manifests/ingress-nginx-priority.yaml"], "externalTrafficPolicy: Local"),
      !contains(output.elemental_file_names, "kubernetes/manifests/traefik-priority.yaml"),
    ])
    error_message = "ingress_vip with ingress-nginx must render the pool and the nginx HelmChartConfig."
  }
}

run "vip_external_mode_fails" {
  command = plan

  variables {
    ingress_vip = "10.20.0.41"
  }

  expect_failures = [var.ingress_vip]
}

run "vip_invalid_ip_fails" {
  command = plan

  variables {
    api_vip_mode = "managed"
    ingress_vip  = "10.20.0.256"
  }

  expect_failures = [var.ingress_vip]
}

run "vip_equal_api_vip_fails" {
  command = plan

  variables {
    api_vip_mode = "managed"
    ingress_vip  = "203.0.113.10"
  }

  expect_failures = [var.ingress_vip]
}

run "vip_without_controller_fails" {
  command = plan

  variables {
    api_vip_mode       = "managed"
    ingress_vip        = "10.20.0.41"
    ingress_controller = "none"
  }

  expect_failures = [var.ingress_vip]
}
