# Pre-created IAM: with both names set the module creates no aws_iam_* resource
# and uses the named role and profile; one name alone fails at plan. Mock providers only.

variables {
  region                  = "us-east-1"
  admin_cidrs             = ["198.51.100.0/24"]
  root_password_hash      = "$6$DUMMYSALT$ROOTDUMMYHASHROOTDUMMYHASHROOTDUMMYHASHROOTDUMMYHASHROOTDUMMYHASH0"
  node_user_password_hash = "$6$DUMMYSALT$NODEDUMMYHASHNODEDUMMYHASHNODEDUMMYHASHNODEDUMMYHASHNODEDUMMYHASH0"
  ssh_authorized_keys     = ["ssh-ed25519 AAAADUMMY test"]
  cluster_name            = "out-aws"
  rancher_hostname        = "rancher.example.com"
  zones                   = ["a", "b"]
  control_plane_count     = 3
  image_id                = "ami-0dummyprebuilt00001"
  appco_username          = "DUMMY-APPCO-USER"
  appco_password          = "DUMMY-APPCO-PASSWORD"
  suse_registry_username  = "DUMMY-REGCODE"
  suse_registry_password  = "DUMMY-REGISTRY-PASSWORD"
  nvidia_api_key          = "DUMMY-NVIDIA-API-KEY"
}

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
    target = aws_lb.api
    values = {
      dns_name = "internal-dummy-api-nlb-1234567890.elb.us-east-1.amazonaws.com"
      arn      = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/net/dummy-api/0000000000000001"
    }
  }

  override_resource {
    target = aws_lb.public
    values = {
      dns_name = "dummy-public-nlb-0987654321.elb.us-east-1.amazonaws.com"
      arn      = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/net/dummy-public/0000000000000002"
    }
  }

  # aws_lb_listener validates load_balancer_arn/target_group_arn look like
  # real ARNs client-side, even against a mocked provider -- the mock
  # default for a computed "arn" attribute is not ARN-shaped, so every
  # target group needs one too.
  override_resource {
    target = aws_lb_target_group.api_kube_api
    values = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/dummy-api-6443/0000000000000003" }
  }

  override_resource {
    target = aws_lb_target_group.api_supervisor
    values = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/dummy-api-9345/0000000000000004" }
  }

  override_resource {
    target = aws_lb_target_group.http
    values = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/dummy-http/0000000000000005" }
  }

  override_resource {
    target = aws_lb_target_group.https
    values = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/dummy-https/0000000000000006" }
  }

  override_resource {
    target = aws_lb_target_group.admin_kube_api
    values = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/dummy-admin-6443/0000000000000007" }
  }

  override_resource {
    target = aws_s3_bucket.build
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
    target = random_password.token
    values = {
      result = "DUMMYTOKENDUMMYTOKENDUMMYTOKEN12"
    }
  }

  override_resource {
    target = module.elemental_config.random_password.rancher_bootstrap
    values = {
      result = "DUMMY-RANCHER-BOOTSTRAP-PW"
    }
  }
}

override_resource {
  target = time_static.created
  values = { rfc3339 = "2026-09-30T12:34:56Z" }
}


run "precreated" {
  command = plan

  variables {
    image_id                       = null
    vmimport_role_name             = "pre-vmimport"
    jumphost_instance_profile_name = "pre-jumphost"
  }

  assert {
    condition = alltrue([
      length(aws_iam_role.vmimport) == 0,
      length(aws_iam_role.jumphost) == 0,
      length(aws_iam_role_policy.vmimport) == 0,
      length(aws_iam_role_policy.jumphost) == 0,
      length(aws_iam_instance_profile.jumphost) == 0,
      length(data.aws_iam_policy_document.vmimport_trust) == 0,
      length(data.aws_iam_policy_document.vmimport) == 0,
      length(data.aws_iam_policy_document.jumphost_trust) == 0,
      length(data.aws_iam_policy_document.jumphost) == 0,
    ])
    error_message = "aws_iam_* resources planned although both names are set"
  }

  assert {
    condition     = length(data.aws_iam_role.vmimport) == 1 && length(data.aws_iam_instance_profile.jumphost) == 1
    error_message = "pre-created role and profile are not looked up"
  }

  assert {
    condition     = aws_ebs_snapshot_import.ai_factory[0].role_name == "pre-vmimport" && aws_instance.jumphost[0].iam_instance_profile == "pre-jumphost"
    error_message = "the pre-created names are not wired into the import and the jumphost"
  }
}

run "created_by_default" {
  command = plan

  variables {
    image_id = null
  }

  assert {
    condition     = length(aws_iam_role.vmimport) == 1 && length(aws_iam_role.jumphost) == 1 && length(aws_iam_instance_profile.jumphost) == 1
    error_message = "the module did not plan its own IAM"
  }
}

run "only_role" {
  command = plan

  variables {
    vmimport_role_name = "pre-vmimport"
  }

  expect_failures = [var.vmimport_role_name]
}

run "only_profile" {
  command = plan

  variables {
    jumphost_instance_profile_name = "pre-jumphost"
  }

  expect_failures = [var.vmimport_role_name]
}

run "empty_role" {
  command = plan

  variables {
    vmimport_role_name             = ""
    jumphost_instance_profile_name = "pre-jumphost"
  }

  expect_failures = [var.vmimport_role_name]
}

run "empty_profile" {
  command = plan

  variables {
    vmimport_role_name             = "pre-vmimport"
    jumphost_instance_profile_name = ""
  }

  expect_failures = [var.jumphost_instance_profile_name]
}
