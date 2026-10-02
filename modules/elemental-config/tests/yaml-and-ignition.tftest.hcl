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

run "rendered_files_parse_as_yaml" {
  command = plan

  variables {
    enable_write_node_ip = true
  }

  assert {
    condition = alltrue([
      for path, content in output.elemental_files :
      can(yamldecode(content)) if endswith(path, ".yaml") && !startswith(path, "kubernetes/manifests/") && !endswith(path, "aif-operator.yaml")
    ])
    error_message = "Every rendered .yaml file must parse as YAML."
  }

  assert {
    condition     = can(yamldecode(output.elemental_files["kubernetes/helm/values/aif-operator.yaml"]))
    error_message = "aif-operator.yaml must parse as YAML."
  }

  assert {
    condition     = yamldecode(output.elemental_files["kubernetes/cluster.yaml"]).network.apiVIP == "203.0.113.10"
    error_message = "cluster.yaml must carry the API VIP."
  }

  assert {
    condition     = yamldecode(output.elemental_files["install.yaml"]).kernelCmdLine == var.kernel_cmdline
    error_message = "install.yaml must carry kernel_cmdline verbatim."
  }

  assert {
    condition     = yamldecode(output.elemental_files["kubernetes/config/server.yaml"]).token == "TOKEN"
    error_message = "server.yaml must carry the RKE2 token."
  }

  assert {
    condition     = !can(yamldecode(output.elemental_files["kubernetes/config/server.yaml"])["tls-san"])
    error_message = "server.yaml must have no tls-san when tls_san is empty."
  }

  assert {
    condition     = !strcontains(output.elemental_files["butane.yaml"], "\n# ") && !strcontains(output.elemental_files["release.yaml"], "\n# ")
    error_message = "Rendered files must have comment lines stripped."
  }

  assert {
    condition     = strcontains(output.elemental_files["butane.yaml"], "#!/usr/bin/env bash")
    error_message = "Comment stripping must keep the shebang of embedded scripts."
  }
}

run "tls_san_is_rendered" {
  command = plan

  variables {
    tls_san = ["nlb.example.test", "10.20.0.5"]
  }

  assert {
    condition     = yamldecode(output.elemental_files["kubernetes/config/server.yaml"])["tls-san"] == ["nlb.example.test", "10.20.0.5"]
    error_message = "tls_san entries must be rendered into server.yaml."
  }
}

run "butane_parses_and_carries_extra_hooks" {
  command = plan

  variables {
    enable_write_node_ip = true
    extra_butane_units = [
      { name = "extra.service", contents = "[Service]\nExecStart=/bin/true\n" },
      { name = "other.service", enabled = false },
    ]
    extra_butane_files = [
      { path = "/var/lib/elemental/extra.sh", contents = "#!/bin/sh\necho hi\n" },
    ]
    extra_config_files = {
      "network/configure-network.sh" = "#!/bin/sh\n# comment\necho net\n"
    }
  }

  assert {
    condition = alltrue([
      for u in ["sshd.service", "write-node-ip.service", "extra.service", "other.service"] :
      contains([for x in yamldecode(output.elemental_files["butane.yaml"]).systemd.units : x.name], u)
    ])
    error_message = "butane.yaml must list the built-in and extra units."
  }

  assert {
    condition = alltrue([
      for p in ["/var/lib/elemental/write-node-ip.sh", "/var/lib/elemental/extra.sh"] :
      contains([for x in yamldecode(output.elemental_files["butane.yaml"]).storage.files : x.path], p)
    ])
    error_message = "butane.yaml must list the write-node-ip script and the extra file."
  }

  assert {
    condition     = output.elemental_files["network/configure-network.sh"] == "#!/bin/sh\necho net\n"
    error_message = "extra_config_files must be added, with comments stripped."
  }

  assert {
    condition     = strcontains(output.write_node_ip_script, "VPC_CIDR=\"10.20.0.0/16\"")
    error_message = "write-node-ip.sh must carry vpc_cidr."
  }
}

run "write_node_ip_is_off_by_default" {
  command = plan

  assert {
    condition     = !strcontains(output.elemental_files["butane.yaml"], "write-node-ip")
    error_message = "butane.yaml must not mention write-node-ip unless enable_write_node_ip is set."
  }
}

run "node_ignition_roles_and_canal" {
  command = plan

  variables {
    canal_iface_regex = "^10\\.20\\."
    pod_veth_mtu      = 8850
  }

  assert {
    condition = alltrue([
      for h, j in output.node_runtime_ignition : can(jsondecode(j))
    ])
    error_message = "Per-node Ignition must be valid JSON."
  }

  assert {
    condition     = strcontains(join("", [for f in jsondecode(output.node_runtime_ignition["test-cp-01"]).storage.files : base64decode(trimprefix(f.contents.source, "data:;base64,")) if f.path == "/var/lib/elemental/runtime.env"]), "IS_INIT_NODE=true")
    error_message = "The init node must carry IS_INIT_NODE=true."
  }

  assert {
    condition     = !strcontains(join("", [for f in jsondecode(output.node_runtime_ignition["test-cp-02"]).storage.files : base64decode(trimprefix(f.contents.source, "data:;base64,")) if f.path == "/var/lib/elemental/runtime.env"]), "IS_INIT_NODE")
    error_message = "Joining nodes must not carry IS_INIT_NODE."
  }

  assert {
    condition     = length(jsondecode(output.node_runtime_ignition["test-gpu-01"]).storage.files) == 2
    error_message = "Agents get hostname and runtime.env only: no canal manifest, no node-ip."
  }

  assert {
    condition     = length(jsondecode(output.node_runtime_ignition["test-cp-03"]).storage.files) == 4
    error_message = "A server with node_ip gets hostname, runtime.env, node-ip and canal."
  }

  assert {
    condition = yamldecode(yamldecode(base64decode(trimprefix([
      for f in jsondecode(output.node_runtime_ignition["test-cp-01"]).storage.files : f.contents.source if f.path == "/var/lib/rancher/rke2/server/manifests/canal.yaml"
    ][0], "data:;base64,"))).spec.valuesContent).calico.vethuMTU == 8850
    error_message = "The canal manifest must carry pod_veth_mtu."
  }
}

run "server_kubeconfig_group_readable" {
  command = plan

  assert {
    condition     = yamldecode(output.elemental_files["kubernetes/config/server.yaml"])["write-kubeconfig-mode"] == "0640"
    error_message = "server.yaml must set write-kubeconfig-mode 0640."
  }

  assert {
    condition     = yamldecode(output.elemental_files["kubernetes/config/server.yaml"])["write-kubeconfig-group"] == "suse"
    error_message = "server.yaml must set write-kubeconfig-group to node_username."
  }
}
