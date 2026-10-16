# Jumphost user_data size: EC2 limits it to 16384 bytes after gzip. The worst
# realistic component set (management cluster plus cert-manager and suse-storage,
# two ssh keys, real AIF 2.3.0 manifest, PEM-sized TLS fixtures) must keep headroom.

variables {
  region                  = "us-east-1"
  admin_cidrs             = ["198.51.100.0/24"]
  root_password_hash      = "$6$DUMMYSALT$ROOTDUMMYHASHROOTDUMMYHASHROOTDUMMYHASHROOTDUMMYHASHROOTDUMMYHASH0"
  node_user_password_hash = "$6$DUMMYSALT$NODEDUMMYHASHNODEDUMMYHASHNODEDUMMYHASHNODEDUMMYHASHNODEDUMMYHASH0"
  ssh_authorized_keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl admin@workstation",
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGvK3QxZ0bJ1y8Tn5d2Wq7LhR4mP9sAeXcUo6VfBtYhD ops@laptop",
  ]
  cluster_name           = "size-aws"
  rancher_hostname       = "rancher.example.com"
  zones                  = ["a", "b", "c"]
  control_plane_count    = 3
  image_id               = null
  components             = ["cert-manager", "rancher", "gpu-operator", "suse-storage", "aif-operator", "security-management", "observability-server", "observability-plugin"]
  appco_username         = "DUMMY-APPCO-USER"
  appco_password         = "DUMMY-APPCO-PASSWORD-DUMMY-APPCO-PASSWORD"
  suse_registry_username = "DUMMY-REGCODE"
  suse_registry_password = "DUMMY-REGISTRY-PASSWORD"
  nvidia_api_key         = "nvapi-DUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMY"

  # Explicit hostnames: the NLB interface lookup is not known at plan time.
  security_hostname      = "neuvector-203.0.113.10.sslip.io"
  observability_hostname = "obs-203.0.113.10.sslip.io"

  security_admin_password       = "DUMMYsecurityAdminPw24ch"
  security_join_token           = "11111111-2222-3333-4444-555555555555"
  observability_license_key     = "DUMMY-LICENSE-KEY-DUMMY-LICENSE-KEY"
  observability_admin_password  = "DUMMYobservabilityPw24"
  observability_bootstrap_token = "DUMMYbootstrapTokenDUMMYbootstrap"
}

mock_provider "http" {}

mock_provider "aws" {
  override_data {
    target = data.aws_availability_zones.available
    values = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }

  override_data {
    target = data.aws_ec2_instance_type_offerings.this
    values = {
      instance_types = ["m7i.xlarge"]
    }
  }

  override_resource {
    target          = aws_lb.api
    override_during = plan
    values = {
      dns_name = "internal-dummy-api-nlb-1234567890.elb.us-east-1.amazonaws.com"
      arn      = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/net/dummy-api/0000000000000001"
    }
  }

  override_resource {
    target          = aws_lb.public
    override_during = plan
    values = {
      dns_name   = "dummy-public-nlb-0987654321.elb.us-east-1.amazonaws.com"
      arn_suffix = "net/dummy-public/0000000000000002"
      arn        = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/net/dummy-public/0000000000000002"
    }
  }

  # Known at plan time: the NLB interface lookup filters on it.
  override_resource {
    target          = aws_subnet.public
    override_during = plan
    values          = { id = "subnet-0123456789abcdef0" }
  }

  # Static IP of the public NLB in the first zone, read only when a security or
  # observability component is enabled.
  override_data {
    target          = data.aws_network_interface.public_nlb
    override_during = plan
    values = {
      association = [{ public_ip = "203.0.113.10" }]
    }
  }

  # aws_lb_listener validates load_balancer_arn/target_group_arn look like
  # real ARNs client-side, even against a mocked provider -- the mock
  # default for a computed "arn" attribute is not ARN-shaped, so every
  # target group needs one too.
  override_resource {
    target          = aws_lb_target_group.api_kube_api
    override_during = plan
    values          = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/dummy-api-6443/0000000000000003" }
  }

  override_resource {
    target          = aws_lb_target_group.api_supervisor
    override_during = plan
    values          = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/dummy-api-9345/0000000000000004" }
  }

  override_resource {
    target          = aws_lb_target_group.http
    override_during = plan
    values          = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/dummy-http/0000000000000005" }
  }

  override_resource {
    target          = aws_lb_target_group.https
    override_during = plan
    values          = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/dummy-https/0000000000000006" }
  }

  override_resource {
    target          = aws_lb_target_group.admin_kube_api
    override_during = plan
    values          = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/dummy-admin-6443/0000000000000007" }
  }

  override_resource {
    target          = aws_s3_bucket.build
    override_during = plan
    values = {
      id = "dummy-build-bucket-000000"
    }
  }

  # These four are aws_iam_policy_document data sources: normally computed
  # locally by the provider (no API call), but under mock_provider they still
  # need an override -- the default mock value for a computed string
  # attribute is "", and aws_iam_role/aws_iam_role_policy's schema validates
  # assume_role_policy/policy as parseable JSON client-side even against a
  # mocked provider, so "" fails plan with "not a JSON object".
  override_data {
    target = data.aws_iam_policy_document.vmimport_trust
    values = {
      json = jsonencode({ Version = "2012-10-17", Statement = [] })
    }
  }

  override_data {
    target = data.aws_iam_policy_document.vmimport
    values = {
      json = jsonencode({ Version = "2012-10-17", Statement = [] })
    }
  }

  override_data {
    target = data.aws_iam_policy_document.jumphost_trust
    values = {
      json = jsonencode({ Version = "2012-10-17", Statement = [] })
    }
  }

  override_data {
    target = data.aws_iam_policy_document.jumphost
    values = {
      json = jsonencode({ Version = "2012-10-17", Statement = [] })
    }
  }
}

mock_provider "aws" {
  alias = "nodes"
}

mock_provider "random" {
  override_resource {
    target          = random_id.bucket_suffix
    override_during = plan
    values          = { hex = "0123456789abcdef", b64_url = "ASNFZ4mrze8" }
  }

  override_resource {
    target          = random_password.token
    override_during = plan
    values = {
      result = "DUMMYTOKENDUMMYTOKENDUMMYTOKEN12"
    }
  }

  override_resource {
    target          = module.elemental_config.random_password.rancher_bootstrap
    override_during = plan
    values = {
      result = "DUMMY-RANCHER-BOOTSTRAP-PW"
    }
  }
}

override_resource {
  target          = time_static.created
  override_during = plan
  values          = { rfc3339 = "2026-09-30T12:34:56Z" }
}


override_data {
  target = module.elemental_config.data.http.aif_release_manifest
  values = {
    status_code   = 200
    response_body = file("tests/fixtures/release_manifest.yaml")
  }
}

override_resource {
  target          = module.elemental_config.tls_private_key.ca
  override_during = plan
  values          = { private_key_pem = file("tests/fixtures/tls-ca-key.txt") }
}

override_resource {
  target          = module.elemental_config.tls_self_signed_cert.ca
  override_during = plan
  values          = { cert_pem = file("tests/fixtures/tls-ca-cert.txt") }
}

override_resource {
  target          = module.elemental_config.tls_private_key.ingress
  override_during = plan
  values          = { private_key_pem = file("tests/fixtures/tls-ingress-key.txt") }
}

override_resource {
  target          = module.elemental_config.tls_locally_signed_cert.ingress
  override_during = plan
  values          = { cert_pem = file("tests/fixtures/tls-ingress-cert.txt") }
}

override_resource {
  target          = module.elemental_config.tls_private_key.neuvector_backend
  override_during = plan
  values          = { private_key_pem = file("tests/fixtures/tls-backend-key.txt") }
}

override_resource {
  target          = module.elemental_config.tls_locally_signed_cert.neuvector_backend
  override_during = plan
  values          = { cert_pem = file("tests/fixtures/tls-backend-cert.txt") }
}

override_resource {
  target          = module.elemental_config.tls_cert_request.ingress
  override_during = plan
  values          = { cert_request_pem = "unused" }
}

override_resource {
  target          = module.elemental_config.tls_cert_request.neuvector_backend
  override_during = plan
  values          = { cert_request_pem = "unused" }
}

# A plan evaluates the aws_instance.jumphost[0] precondition (EC2's 16384 limit)
# too. Apply is avoided: it would run the raw_ready provisioner against S3.
run "jumphost_user_data_size" {
  command = plan

  assert {
    condition     = nonsensitive(local.jumphost_user_data_bytes) <= 16384
    error_message = "Jumphost user_data is ${nonsensitive(local.jumphost_user_data_bytes)} bytes with every management component, over EC2's 16384."
  }
}
