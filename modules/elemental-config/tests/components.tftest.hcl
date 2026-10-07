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

run "default_components_in_canonical_order" {
  command = plan

  assert {
    condition     = output.enabled_components == ["rancher", "gpu-operator", "local-path-provisioner", "aif-operator"]
    error_message = "Default components must render in canonical order."
  }

  assert {
    condition     = length(output.enabled_sysexts) == 0
    error_message = "The default component set needs no systemd extension."
  }

  assert {
    condition     = !strcontains(output.elemental_files["release.yaml"], "cert-manager")
    error_message = "cert-manager must not be injected: elemental resolves chart dependencies itself."
  }

  assert {
    condition = alltrue([
      for p in [
        "kubernetes/helm/values/rancher.yaml",
        "kubernetes/helm/values/gpu-operator.yaml",
        "kubernetes/helm/values/local-path-provisioner.yaml",
        "kubernetes/helm/values/aif-operator.yaml",
        "kubernetes/manifests/local-path-provisioner-pull-secret-priority.yaml",
        "kubernetes/manifests/traefik-priority.yaml",
      ] : contains(output.elemental_file_names, p)
    ])
    error_message = "The default set must render its values files and manifests."
  }

  assert {
    condition     = alltrue([for p in output.elemental_file_names : endswith(p, "-priority.yaml") if startswith(p, "kubernetes/manifests/")])
    error_message = "Image manifests must be *-priority.yaml: elemental applies the others only after every HelmChart job completes."
  }

  assert {
    condition     = strcontains(output.elemental_files["butane.yaml"], "local-path-prep.service") && !strcontains(output.elemental_files["butane.yaml"], "iscsi-prep")
    error_message = "local-path-prep is on and iscsi-prep is off by default."
  }
}

run "component_order_does_not_change_the_render" {
  command = plan

  variables {
    components = ["aif-operator", "local-path-provisioner", "gpu-operator", "rancher"]
  }

  assert {
    condition     = output.build_hash == run.default_components_in_canonical_order.build_hash
    error_message = "Reordering components must not change build_hash."
  }
}

run "storage_chart_pulls_in_its_sysext" {
  command = plan

  variables {
    components = ["rancher", "suse-storage", "aif-operator"]
  }

  assert {
    condition     = join(",", output.enabled_sysexts) == "suse-storage"
    error_message = "suse-storage must enable its systemd extension."
  }

  assert {
    condition     = yamldecode(output.elemental_files["release.yaml"]).components.systemd[0].extension == "suse-storage"
    error_message = "release.yaml must list the suse-storage extension."
  }

  assert {
    condition     = strcontains(output.elemental_files["butane.yaml"], "iscsi-prep.service") && !strcontains(output.elemental_files["butane.yaml"], "local-path-prep")
    error_message = "iscsi-prep is on and local-path-prep is off for suse-storage."
  }

  assert {
    condition     = !contains(output.elemental_file_names, "kubernetes/manifests/local-path-provisioner-pull-secret-priority.yaml")
    error_message = "No local-path pull secret without local-path-provisioner."
  }

}

run "ingress_none_drops_traefik_config" {
  command = plan

  variables {
    ingress_controller = "none"
  }

  assert {
    condition     = !contains(output.elemental_file_names, "kubernetes/manifests/traefik-priority.yaml")
    error_message = "Only ingress_controller = traefik renders the Traefik HelmChartConfig."
  }
}

run "gpu_operator_gating" {
  command = plan

  variables {
    components = ["rancher", "aif-operator"]
  }

  assert {
    condition     = !contains(output.elemental_file_names, "kubernetes/helm/values/gpu-operator.yaml")
    error_message = "No gpu-operator values file when the component is off."
  }
}

run "gpu_operator_values_render" {
  command = plan

  variables {
    gpu_driver_repository = "example.test/nvidia"
    gpu_driver_version    = "999"
  }

  assert {
    condition     = yamldecode(output.elemental_files["kubernetes/helm/values/gpu-operator.yaml"]).driver.version == "999"
    error_message = "gpu_driver_version must reach the gpu-operator values."
  }
}

run "aif_operator_requires_rancher" {
  command = plan

  variables {
    components = ["aif-operator"]
  }

  expect_failures = [var.components]
}

run "suse_storage_single_server_rejected" {
  command = plan

  variables {
    components = ["rancher", "suse-storage", "aif-operator"]
    nodes = [
      { hostname = "test-cp-01", type = "server", init = true },
      { hostname = "test-gpu-01", type = "agent" },
    ]
  }

  expect_failures = [var.suse_storage_nodes]
}

run "suse_storage_values_ignore_server_count" {
  command = plan

  variables {
    components = ["rancher", "suse-storage", "aif-operator"]
  }

  assert {
    condition     = !strcontains(output.elemental_files["kubernetes/helm/values/suse-storage.yaml"], "ReplicaCount")
    error_message = "suse-storage values must not depend on the node count, or scale-out rebuilds the image."
  }
}

run "suse_storage_disks_by_role" {
  command = plan

  variables {
    components         = ["rancher", "suse-storage", "aif-operator"]
    suse_storage_nodes = ["worker", "gpu"]
    nodes = [
      { hostname = "test-cp-01", type = "server", init = true },
      { hostname = "test-wk-01", type = "agent", role = "worker" },
      { hostname = "test-wk-02", type = "agent", role = "worker" },
      { hostname = "test-gpu-01", type = "agent", role = "gpu" },
    ]
  }

  assert {
    condition = alltrue([
      for h, disk in { "test-cp-01" = false, "test-wk-01" = true, "test-wk-02" = true, "test-gpu-01" = true } :
      contains([for f in jsondecode(output.node_runtime_ignition[h]).storage.files : f.path], "/etc/rancher/rke2/config.yaml.d/90-longhorn-disk.yaml") == disk
    ])
    error_message = "The Longhorn default-disk drop-in must go to exactly the nodes whose role is in suse_storage_nodes."
  }

  assert {
    condition     = !strcontains(output.elemental_files["kubernetes/config/server.yaml"], "longhorn") && !strcontains(output.elemental_files["kubernetes/config/agent.yaml"], "longhorn")
    error_message = "The Longhorn label must not be in the image config."
  }
}

run "suse_storage_default_on_servers" {
  command = plan

  variables {
    components = ["rancher", "suse-storage", "aif-operator"]
  }

  assert {
    condition = alltrue([
      for h, disk in { "test-cp-01" = true, "test-cp-03" = true, "test-gpu-01" = false } :
      contains([for f in jsondecode(output.node_runtime_ignition[h]).storage.files : f.path], "/etc/rancher/rke2/config.yaml.d/90-longhorn-disk.yaml") == disk
    ])
    error_message = "By default only control-plane nodes get the Longhorn default-disk drop-in."
  }
}

run "suse_storage_nodes_keep_hash" {
  command = plan

  variables {
    components         = ["rancher", "suse-storage", "aif-operator"]
    suse_storage_nodes = ["control_plane", "gpu"]
  }

  assert {
    condition     = output.build_hash == run.suse_storage_default_on_servers.build_hash
    error_message = "suse_storage_nodes must not change build_hash."
  }
}

run "suse_storage_too_few_disk_nodes" {
  command = plan

  variables {
    components         = ["rancher", "suse-storage", "aif-operator"]
    suse_storage_nodes = ["gpu"]
  }

  expect_failures = [var.suse_storage_nodes]
}

run "agent_role_must_not_be_control_plane" {
  command = plan

  variables {
    nodes = [
      { hostname = "test-cp-01", type = "server", init = true },
      { hostname = "test-gpu-01", type = "agent", role = "control_plane" },
    ]
  }

  expect_failures = [var.nodes]
}

run "suse_storage_disks_by_role_and_pool" {
  command = plan

  variables {
    components         = ["rancher", "suse-storage", "aif-operator"]
    suse_storage_nodes = ["control_plane", "storage"]
    nodes = [
      { hostname = "test-cp-01", type = "server", init = true, pool = "cp" },
      { hostname = "test-storage-01", type = "agent", role = "worker", pool = "storage" },
      { hostname = "test-storage-02", type = "agent", role = "worker", pool = "storage" },
      { hostname = "test-general-01", type = "agent", role = "worker", pool = "general" },
      { hostname = "test-gpu-01", type = "agent", role = "gpu", pool = "gpu" },
    ]
  }

  assert {
    condition = alltrue([
      for h, disk in { "test-cp-01" = true, "test-storage-01" = true, "test-storage-02" = true, "test-general-01" = false, "test-gpu-01" = false } :
      contains([for f in jsondecode(output.node_runtime_ignition[h]).storage.files : f.path], "/etc/rancher/rke2/config.yaml.d/90-longhorn-disk.yaml") == disk
    ])
    error_message = "The Longhorn default-disk drop-in must go to nodes whose role or pool is in suse_storage_nodes."
  }
}

run "suse_storage_unknown_pool_rejected" {
  command = plan

  variables {
    components         = ["rancher", "suse-storage", "aif-operator"]
    suse_storage_nodes = ["control_plane", "nosuchpool"]
  }

  expect_failures = [var.suse_storage_nodes]
}
