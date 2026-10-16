mock_provider "http" {}

# TLS results are unknown at plan time; fixed fixtures keep the render known;
# random text of PEM length, not keys, so sizes stay realistic.
mock_provider "tls" {}

override_data {
  target = data.http.aif_release_manifest
  values = {
    status_code   = 200
    response_body = file("tests/fixtures/release_manifest.yaml")
  }
}

override_resource {
  target          = tls_private_key.ca
  override_during = plan
  values          = { private_key_pem = file("tests/fixtures/tls-ca-key.txt") }
}

override_resource {
  target          = tls_self_signed_cert.ca
  override_during = plan
  values          = { cert_pem = file("tests/fixtures/tls-ca-cert.txt") }
}

override_resource {
  target          = tls_private_key.ingress
  override_during = plan
  values          = { private_key_pem = file("tests/fixtures/tls-ingress-key.txt") }
}

override_resource {
  target          = tls_cert_request.ingress
  override_during = plan
  values          = { cert_request_pem = "unused" }
}

override_resource {
  target          = tls_locally_signed_cert.ingress
  override_during = plan
  values          = { cert_pem = file("tests/fixtures/tls-ingress-cert.txt") }
}

override_resource {
  target          = tls_private_key.neuvector_backend
  override_during = plan
  values          = { private_key_pem = file("tests/fixtures/tls-backend-key.txt") }
}

override_resource {
  target          = tls_cert_request.neuvector_backend
  override_during = plan
  values          = { cert_request_pem = "unused" }
}

override_resource {
  target          = tls_locally_signed_cert.neuvector_backend
  override_during = plan
  values          = { cert_pem = file("tests/fixtures/tls-backend-cert.txt") }
}

variables {
  cluster_name        = "test"
  api_vip             = "203.0.113.10"
  api_host            = "rke2-203.0.113.10.sslip.io"
  ingress_address     = "203.0.113.10"
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

  # Every secret is set, so no random_* result makes the render unknown.
  security_admin_password       = "nv-admin"
  security_join_token           = "11111111-2222-3333-4444-555555555555"
  observability_license_key     = "LICENSE"
  observability_admin_password  = "obs-admin"
  observability_bootstrap_token = "obs-bootstrap"
}

run "no_addons_by_default" {
  command = plan

  assert {
    condition     = output.security == null && output.observability == null
    error_message = "Add-on outputs must be null without add-on components."
  }

  assert {
    condition     = nonsensitive(output.security_credentials == null && output.observability_credentials == null)
    error_message = "Add-on credential outputs must be null without add-on components."
  }

  assert {
    condition     = !anytrue([for p in output.elemental_file_names : strcontains(p, "security") || strcontains(p, "observability")])
    error_message = "No add-on manifest without add-on components."
  }
}

run "observability_server_adds_agent" {
  command = plan

  variables {
    components = ["observability-server", "rancher", "local-path-provisioner", "aif-operator"]
  }

  assert {
    condition     = output.enabled_components == ["rancher", "local-path-provisioner", "aif-operator", "observability-server", "observability-agent"]
    error_message = "observability-server must add observability-agent, after the charts, in canonical order."
  }

  assert {
    condition = alltrue([
      contains(output.elemental_file_names, "kubernetes/manifests/observability-server-priority.yaml"),
      contains(output.elemental_file_names, "kubernetes/manifests/observability-agent-priority.yaml"),
      !contains(output.elemental_file_names, "kubernetes/manifests/observability-plugin-priority.yaml"),
      !contains(output.elemental_file_names, "kubernetes/manifests/security-priority.yaml"),
      !contains(output.elemental_file_names, "kubernetes/manifests/security-ui-extension-priority.yaml"),
    ])
    error_message = "observability-server renders the server and agent manifests only."
  }

  assert {
    condition     = !strcontains(output.elemental_files["release.yaml"], "observability") && !strcontains(output.elemental_files["release.yaml"], "neuvector")
    error_message = "Add-ons must not enter release.yaml."
  }

  assert {
    condition = alltrue([
      output.observability.url == "https://obs-203.0.113.10.sslip.io",
      output.observability.otlp_grpc_endpoint == "otlp-obs-203.0.113.10.sslip.io:443",
      output.observability.otlp_http_endpoint == "https://otlp-http-obs-203.0.113.10.sslip.io",
      trimspace(output.observability.ca_pem) == trimspace(file("tests/fixtures/tls-ca-cert.txt")),
    ])
    error_message = "observability output must carry the sslip.io URLs, OTLP endpoints and the CA."
  }

  assert {
    condition     = nonsensitive(output.observability_credentials.admin_password == "obs-admin" && output.observability_credentials.bootstrap_token == "obs-bootstrap")
    error_message = "observability_credentials must return the supplied secrets."
  }

  assert {
    condition     = output.security == null
    error_message = "No security output with observability only."
  }

  assert {
    condition = alltrue([
      strcontains(output.elemental_files["kubernetes/manifests/observability-server-priority.yaml"], "otlp-http-obs-203.0.113.10.sslip.io"),
      strcontains(output.elemental_files["kubernetes/manifests/observability-server-priority.yaml"], "https://rancher.example.test/"),
    ])
    error_message = "The server manifest must carry the OTLP HTTP host and the local Rancher origin."
  }
}

run "local_agent_has_no_ca" {
  command = plan

  variables {
    components = ["rancher", "observability-server"]
  }

  assert {
    condition = alltrue([
      strcontains(output.elemental_files["kubernetes/manifests/observability-agent-priority.yaml"], "http://suse-observability-otel-collector.suse-observability.svc.cluster.local:4318"),
      strcontains(output.elemental_files["kubernetes/manifests/observability-agent-priority.yaml"], "otlp_http/suse-observability"),
      !strcontains(output.elemental_files["kubernetes/manifests/observability-agent-priority.yaml"], "otlp_grpc/suse-observability"),
      !strcontains(output.elemental_files["kubernetes/manifests/observability-agent-priority.yaml"], "tls.pem"),
    ])
    error_message = "A local agent uses the in-cluster collector and carries no CA."
  }
}

run "remote_agent_carries_ca" {
  command = plan

  variables {
    components                    = ["rancher", "observability-agent"]
    observability_server_url      = "https://obs.remote.example.test/"
    observability_ca_pem          = "REMOTE-CA-PEM"
    observability_bootstrap_token = "remote-token"
  }

  assert {
    condition     = alltrue([for p in output.elemental_file_names : !strcontains(p, "observability-server")])
    error_message = "An agent-only cluster renders no server manifest."
  }

  assert {
    condition = alltrue([
      strcontains(output.elemental_files["kubernetes/manifests/observability-agent-priority.yaml"], "REMOTE-CA-PEM"),
      strcontains(output.elemental_files["kubernetes/manifests/observability-agent-priority.yaml"], "otlp-obs.remote.example.test:443"),
      strcontains(output.elemental_files["kubernetes/manifests/observability-agent-priority.yaml"], "https://obs.remote.example.test/receiver/stsAgent"),
    ])
    error_message = "A remote agent carries the CA, the OTLP host and the receiver URL derived from observability_server_url."
  }

  assert {
    condition     = output.observability == null
    error_message = "Only observability-server fills the observability output."
  }
}

run "remote_agent_needs_url" {
  command = plan

  variables {
    components                    = ["rancher", "observability-agent"]
    observability_bootstrap_token = null
  }

  expect_failures = [terraform_data.addon_guards]
}

run "opensearch_credentials_enable_the_receiver" {
  command = plan

  variables {
    components                           = ["rancher", "observability-server"]
    observability_opensearch_credentials = { username = "os-user", password = "os-pass" }
  }

  assert {
    condition     = strcontains(output.elemental_files["kubernetes/manifests/observability-agent-priority.yaml"], "os-pass") && !strcontains(run.local_agent_has_no_ca.elemental_files["kubernetes/manifests/observability-agent-priority.yaml"], "os-pass")
    error_message = "OpenSearch credentials must reach the collector only when set."
  }
}

run "plugin_local_and_remote" {
  command = plan

  variables {
    components = ["rancher", "observability-server", "observability-plugin"]
  }

  assert {
    condition = alltrue([
      strcontains(output.elemental_files["kubernetes/manifests/observability-plugin-priority.yaml"], "https://obs-203.0.113.10.sslip.io"),
      !strcontains(output.elemental_files["kubernetes/manifests/observability-plugin-priority.yaml"], indent(4, chomp(file("tests/fixtures/tls-ca-cert.txt")))),
    ])
    error_message = "A local plugin points at the local host and carries no CA."
  }
}

run "plugin_remote" {
  command = plan

  variables {
    components                    = ["rancher", "observability-plugin"]
    observability_server_url      = "https://obs.remote.example.test"
    observability_ca_pem          = "REMOTE-CA-PEM"
    observability_bootstrap_token = "remote-token"
  }

  assert {
    condition = alltrue([
      strcontains(output.elemental_files["kubernetes/manifests/observability-plugin-priority.yaml"], "REMOTE-CA-PEM"),
      strcontains(output.elemental_files["kubernetes/manifests/observability-plugin-priority.yaml"], "https://obs.remote.example.test"),
      !contains(output.elemental_file_names, "kubernetes/manifests/observability-agent-priority.yaml"),
    ])
    error_message = "A remote plugin carries the CA and URL and renders no agent."
  }
}

run "security_management" {
  command = plan

  variables {
    components = ["rancher", "security-management"]
  }

  assert {
    condition = alltrue([
      strcontains(output.elemental_files["kubernetes/manifests/security-priority.yaml"], "clusterName: \"local\""),
      strcontains(output.elemental_files["kubernetes/manifests/security-priority.yaml"], "Role: fedAdmin"),
      !strcontains(output.elemental_files["kubernetes/manifests/security-priority.yaml"], "rollout restart"),
      strcontains(output.elemental_files["kubernetes/manifests/security-priority.yaml"], "kubernetes.io/ingress.class: traefik"),
      contains(output.elemental_file_names, "kubernetes/manifests/security-priority.yaml"),
      contains(output.elemental_file_names, "kubernetes/manifests/security-ui-extension-priority.yaml"),
      !contains(output.elemental_file_names, "kubernetes/manifests/observability-server-priority.yaml"),
      !contains(output.elemental_file_names, "kubernetes/manifests/observability-agent-priority.yaml"),
    ])
    error_message = "security-management with rancher renders the security and UI extension manifests only."
  }

  assert {
    condition = alltrue([
      strcontains(output.elemental_files["kubernetes/manifests/security-priority.yaml"], "109.0.6+up2.11.2"),
      strcontains(output.elemental_files["kubernetes/manifests/security-priority.yaml"], "neuvector-svc-controller-fed-master"),
      !strcontains(output.elemental_files["kubernetes/manifests/security-priority.yaml"], "neuvector-svc-controller-fed-managed"),
      !strcontains(output.elemental_files["kubernetes/manifests/security-priority.yaml"], "Managed_Rest_Info"),
      strcontains(output.elemental_files["kubernetes/manifests/security-priority.yaml"], "fed-neuvector-203.0.113.10.sslip.io"),
    ])
    error_message = "The management cluster maps the Rancher 2.14 minor to the 109.0.6+up2.11.2 chart and routes federation to the master service."
  }

  assert {
    condition = alltrue([
      output.security.role == "management",
      output.security.url == "https://neuvector-203.0.113.10.sslip.io",
      output.security.federation_endpoint == "fed-neuvector-203.0.113.10.sslip.io:443",
    ])
    error_message = "security output shape on the management cluster."
  }

  assert {
    condition     = nonsensitive(output.security_credentials.admin_password == "nv-admin" && output.security_credentials.join_token == "11111111-2222-3333-4444-555555555555")
    error_message = "security_credentials must return the supplied secrets."
  }
}

run "security_management_without_rancher_has_no_extension" {
  command = plan

  variables {
    components = ["security-management"]
  }

  assert {
    condition     = !contains(output.elemental_file_names, "kubernetes/manifests/security-ui-extension-priority.yaml") && contains(output.elemental_file_names, "kubernetes/manifests/security-priority.yaml")
    error_message = "The NeuVector UI extension needs rancher."
  }
}

run "security_downstream" {
  command = plan

  variables {
    components                = ["rancher", "security-downstream"]
    security_primary_endpoint = "mgmt.example.test:8443"
  }

  assert {
    condition = alltrue([
      strcontains(output.elemental_files["kubernetes/manifests/security-priority.yaml"], "Managed_Rest_Info"),
      strcontains(output.elemental_files["kubernetes/manifests/security-priority.yaml"], "delete pods -l app=neuvector-controller-pod"),
      strcontains(output.elemental_files["kubernetes/manifests/security-priority.yaml"], "kicked"),
      !strcontains(output.elemental_files["kubernetes/manifests/security-priority.yaml"], "Role: fedAdmin"),
      !strcontains(output.elemental_files["kubernetes/manifests/security-priority.yaml"], "rollout restart"),
      strcontains(output.elemental_files["kubernetes/manifests/security-priority.yaml"], "neuvector-svc-controller-fed-managed"),
      !strcontains(output.elemental_files["kubernetes/manifests/security-priority.yaml"], "neuvector-svc-controller-fed-master"),
      strcontains(output.elemental_files["kubernetes/manifests/security-priority.yaml"], "mgmt.example.test"),
      !contains(output.elemental_file_names, "kubernetes/manifests/security-ui-extension-priority.yaml"),
    ])
    error_message = "A downstream cluster declares Managed_Rest_Info, routes federation to the managed service and has no UI extension."
  }

  assert {
    condition = alltrue([
      output.security.role == "downstream",
      output.security.url == null,
      output.security.federation_endpoint == "fed-neuvector-203.0.113.10.sslip.io:443",
    ])
    error_message = "security output shape on a downstream cluster."
  }
}

run "security_downstream_needs_endpoint" {
  command = plan

  variables {
    components = ["rancher", "security-downstream"]
  }

  expect_failures = [terraform_data.addon_guards]
}

run "neuvector_version_unknown_minor" {
  command = plan

  override_data {
    target = data.http.aif_release_manifest
    values = {
      status_code   = 200
      response_body = file("tests/fixtures/release_manifest_rancher_unknown.yaml")
    }
  }

  variables {
    components = ["rancher", "security-management"]
  }

  expect_failures = [terraform_data.addon_guards]
}

run "ingress_address_required_for_defaults" {
  command = plan

  variables {
    components      = ["rancher", "security-management"]
    ingress_address = null
  }

  expect_failures = [terraform_data.addon_guards]
}

run "explicit_hostnames_need_no_ingress_address" {
  command = plan

  variables {
    components             = ["rancher", "security-management", "observability-server"]
    ingress_address        = null
    security_hostname      = "nv.example.test"
    observability_hostname = "obs.example.test"
  }

  assert {
    condition     = output.observability.url == "https://obs.example.test" && output.security.url == "https://nv.example.test"
    error_message = "Explicit hostnames must work without ingress_address."
  }
}

run "ingress_domain_sets_default_hostnames" {
  command = plan

  variables {
    components      = ["rancher", "security-management", "observability-server"]
    ingress_address = null
    ingress_domain  = "aif.example.com"
  }

  assert {
    condition = alltrue([
      output.observability.url == "https://obs.aif.example.com",
      output.observability.otlp_grpc_endpoint == "otlp-obs.aif.example.com:443",
      output.observability.otlp_http_endpoint == "https://otlp-http-obs.aif.example.com",
      output.security.url == "https://neuvector.aif.example.com",
      output.security.federation_endpoint == "fed-neuvector.aif.example.com:443",
    ])
    error_message = "ingress_domain must derive obs.<domain> and neuvector.<domain> without ingress_address."
  }
}

run "explicit_hostname_beats_ingress_domain" {
  command = plan

  variables {
    components             = ["rancher", "security-management", "observability-server"]
    ingress_address        = null
    ingress_domain         = "aif.example.com"
    observability_hostname = "obs.example.test"
  }

  assert {
    condition     = output.observability.url == "https://obs.example.test" && output.security.url == "https://neuvector.aif.example.com"
    error_message = "An explicit hostname must win over ingress_domain."
  }
}

run "all_addons_share_one_ca" {
  command = plan

  variables {
    components = ["rancher", "security-management", "observability-server"]
  }

  assert {
    condition     = strcontains(output.elemental_files["kubernetes/manifests/security-priority.yaml"], indent(4, chomp(file("tests/fixtures/tls-ca-cert.txt"))))
    error_message = "The management cluster ships the CA to NeuVector."
  }
}

run "build_hash_baseline" {
  command = plan

  variables {
    components = ["rancher", "observability-server"]
  }
}

run "sizing_profile_changes_build_hash" {
  command = plan

  variables {
    components                   = ["rancher", "observability-server"]
    observability_sizing_profile = "10-nonha"
  }

  assert {
    condition     = output.build_hash != run.build_hash_baseline.build_hash
    error_message = "observability_sizing_profile must change build_hash."
  }
}

run "every_addon_manifest_is_priority" {
  command = plan

  variables {
    components = ["rancher", "security-management", "observability-server", "observability-plugin"]
  }

  assert {
    condition     = alltrue([for p in output.elemental_file_names : endswith(p, "-priority.yaml") if startswith(p, "kubernetes/manifests/")])
    error_message = "Add-on manifests must be *-priority.yaml."
  }

  assert {
    condition     = length([for p in output.elemental_file_names : p if startswith(p, "kubernetes/manifests/") && (strcontains(p, "security") || strcontains(p, "observability"))]) == 5
    error_message = "All five add-on manifests must render."
  }
}

run "add_on_manifests_are_valid_yaml" {
  command = plan

  variables {
    components = ["rancher", "security-management", "observability-server", "observability-plugin"]
  }

  assert {
    condition = alltrue(flatten([
      for p in output.elemental_file_names : [
        for d in split("\n---\n", output.elemental_files[p]) : can(yamldecode(d)) if trimspace(d) != ""
      ] if startswith(p, "kubernetes/manifests/") && (strcontains(p, "security") || strcontains(p, "observability"))
    ]))
    error_message = "Every document of an add-on manifest must be valid YAML."
  }
}

# Size budget: gzip + base64 per file, as the aws jumphost user_data carries
# them (limit 16 KiB for everything). Measured with realistic PEMs (tests/fixtures/tls-*.pem):
# all five files 20128 B; server + agent 9376 B; security 7720 B.
run "addon_size_budget" {
  command = plan

  variables {
    components = ["rancher", "security-management", "observability-server", "observability-plugin", "local-path-provisioner", "aif-operator", "gpu-operator"]
  }

  assert {
    condition = nonsensitive(sum([
      for p in ["observability-server", "observability-agent", "observability-plugin", "security", "security-ui-extension"] :
      length(base64gzip(output.elemental_files["kubernetes/manifests/${p}-priority.yaml"]))
    ])) <= 23000
    error_message = "The five add-on manifests exceed their 23000-byte gzip+base64 budget (measured 22284)."
  }

  assert {
    condition = nonsensitive(sum([
      for p in ["observability-server", "observability-agent"] :
      length(base64gzip(output.elemental_files["kubernetes/manifests/${p}-priority.yaml"]))
    ])) <= 10000
    error_message = "observability-server plus its agent exceed their 10000-byte gzip+base64 budget (measured 9376)."
  }

  assert {
    condition     = nonsensitive(length(base64gzip(output.elemental_files["kubernetes/manifests/security-priority.yaml"]))) <= 9500
    error_message = "security-priority.yaml exceeds its 9500-byte gzip+base64 budget (measured <9400)."
  }
}

run "generated_secrets_plan" {
  command = plan

  variables {
    components                    = ["rancher", "security-management", "observability-server"]
    security_admin_password       = null
    security_join_token           = null
    observability_admin_password  = null
    observability_bootstrap_token = null
  }

  assert {
    condition     = output.enabled_components == ["rancher", "observability-server", "observability-agent", "security-management"]
    error_message = "Generated secrets must not break the plan."
  }
}

run "observability_agent_mounts_debugfs" {
  command = plan

  variables {
    components = ["rancher", "observability-server"]
  }

  assert {
    condition     = strcontains(output.elemental_files["butane.yaml"], "sys-kernel-debug.mount")
    error_message = "observability-agent needs debugfs mounted on the nodes for its eBPF tracer."
  }
}

run "no_debugfs_without_observability_agent" {
  command = plan

  assert {
    condition     = !strcontains(output.elemental_files["butane.yaml"], "sys-kernel-debug.mount")
    error_message = "debugfs must stay unmounted unless observability-agent is enabled."
  }
}
