# Realistic management cluster (rancher, security, observability, AIF, GPU), two
# ed25519 keys, real AIF 2.3.0 manifest. vultr, exoscale and evroc deliver the
# config as this one bundle inside user_data (32 KiB limit; exoscale counts the
# base64 of the whole user_data), so it must keep headroom.

mock_provider "http" {}

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
  target          = tls_locally_signed_cert.neuvector_backend
  override_during = plan
  values          = { cert_pem = file("tests/fixtures/tls-backend-cert.txt") }
}

override_resource {
  target          = tls_cert_request.ingress
  override_during = plan
  values          = { cert_request_pem = "unused" }
}

override_resource {
  target          = tls_cert_request.neuvector_backend
  override_during = plan
  values          = { cert_request_pem = "unused" }
}

variables {
  cluster_name            = "size"
  api_vip                 = "203.0.113.10"
  api_host                = "rke2-203.0.113.10.sslip.io"
  vpc_cidr                = "10.20.0.0/16"
  rke2_token              = "DUMMYTOKENDUMMYTOKENDUMMYTOKEN12"
  user_data_max_bytes     = 32768
  kernel_cmdline          = "console=ttyS0 ignition.platform.id=test"
  root_password_hash      = "$6$DUMMYSALT$ROOTDUMMYHASHROOTDUMMYHASHROOTDUMMYHASHROOTDUMMYHASHROOTDUMMYHASH0"
  node_user_password_hash = "$6$DUMMYSALT$NODEDUMMYHASHNODEDUMMYHASHNODEDUMMYHASHNODEDUMMYHASHNODEDUMMYHASH0"
  ssh_authorized_keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl admin@workstation",
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGvK3QxZ0bJ1y8Tn5d2Wq7LhR4mP9sAeXcUo6VfBtYhD ops@laptop",
  ]
  nodes                         = [{ hostname = "size-cp-01", type = "server", init = true }]
  components                    = ["rancher", "local-path-provisioner", "gpu-operator", "aif-operator", "security-management", "observability-server", "observability-plugin"]
  rancher_hostname              = "rancher-203.0.113.10.sslip.io"
  security_hostname             = "neuvector-203.0.113.10.sslip.io"
  observability_hostname        = "obs-203.0.113.10.sslip.io"
  appco_username                = "DUMMY-APPCO-USER"
  appco_password                = "DUMMY-APPCO-PASSWORD"
  suse_registry_username        = "DUMMY-REGCODE"
  suse_registry_password        = "DUMMY-REGISTRY-PASSWORD"
  nvidia_api_key                = "nvapi-DUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY"
  security_admin_password       = "DUMMYsecurityAdminPw24ch"
  security_join_token           = "11111111-2222-3333-4444-555555555555"
  observability_license_key     = "DUMMY-LICENSE-KEY-DUMMY-LICENSE-KEY"
  observability_admin_password  = "DUMMYobservabilityPw24"
  observability_bootstrap_token = "DUMMYbootstrapTokenDUMMYbootstrap"
  rancher_bootstrap_password    = "bootstrap"
}

# Measured 18984 characters; the rest of user_data (factory script, cloud-init
# wrapper) adds about 3.5 KB, and exoscale base64-encodes all of it.
run "management_bundle_size" {
  command = plan

  assert {
    condition     = nonsensitive(length(output.config_bundle)) <= 21000
    error_message = "config_bundle is ${nonsensitive(length(output.config_bundle))} characters; vultr, exoscale and evroc need it well under 21000."
  }
}
