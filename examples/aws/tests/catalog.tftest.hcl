# Plans examples/aws with one catalog tfvars file (make test-catalog passes it
# with -var-file), so a validation or precondition change that breaks a shape
# fails CI. AWS mocked; no cloud calls. Credentials below stand in for
# clusters/common-*.tfvars; the CA stands in for addons.auto.tfvars.json.

mock_provider "aws" {
  override_during = plan
}
mock_provider "aws" {
  alias           = "nodes"
  override_during = plan
}
mock_provider "http" {}

override_data {
  target = module.ai_factory.module.elemental_config.data.http.aif_release_manifest
  values = {
    status_code   = 200
    response_body = file("../../modules/elemental-config/tests/fixtures/release_manifest.yaml")
  }
}

override_data {
  target          = module.ai_factory.data.aws_availability_zones.available
  override_during = plan
  values          = { names = ["eu-central-1a", "eu-central-1b", "eu-central-1c"] }
}

# Every instance type the shapes use is offered in every zone.
override_data {
  target          = module.ai_factory.data.aws_ec2_instance_type_offerings.this
  override_during = plan
  values          = { instance_types = ["offered"] }
}

override_data {
  target          = module.ai_factory.data.aws_ami.jumphost
  override_during = plan
  values          = { id = "ami-0dummyjumphost0001" }
}

override_data {
  target          = module.ai_factory.data.aws_network_interface.public_nlb
  override_during = plan
  values = {
    association = [{ allocation_id = null, association_id = null, carrier_ip = null, customer_owned_ip = null, ip_owner_id = null, public_dns_name = null, public_ip = "203.0.113.10" }]
  }
}

# The provider validates policy JSON client-side, even when mocked.
override_data {
  target          = module.ai_factory.data.aws_iam_policy_document.vmimport_trust
  override_during = plan
  values          = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
}

override_data {
  target          = module.ai_factory.data.aws_iam_policy_document.vmimport
  override_during = plan
  values          = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
}

override_data {
  target          = module.ai_factory.data.aws_iam_policy_document.jumphost_trust
  override_during = plan
  values          = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
}

override_data {
  target          = module.ai_factory.data.aws_iam_policy_document.jumphost
  override_during = plan
  values          = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
}

# aws_lb_listener validates the load balancer and target group ARNs client-side.
override_resource {
  target          = module.ai_factory.aws_lb.api
  override_during = plan
  values = {
    dns_name = "aif-api-0000000001.elb.eu-central-1.amazonaws.com"
    arn      = "arn:aws:elasticloadbalancing:eu-central-1:123456789012:loadbalancer/net/aif-api/0000000000000001"
  }
}

override_resource {
  target          = module.ai_factory.aws_lb.public
  override_during = plan
  values = {
    dns_name = "aif-public-0000000002.elb.eu-central-1.amazonaws.com"
    arn      = "arn:aws:elasticloadbalancing:eu-central-1:123456789012:loadbalancer/net/aif-public/0000000000000002"
  }
}

override_resource {
  target          = module.ai_factory.aws_lb_target_group.api_kube_api
  override_during = plan
  values          = { arn = "arn:aws:elasticloadbalancing:eu-central-1:123456789012:targetgroup/aif-api-6443/0000000000000003" }
}

override_resource {
  target          = module.ai_factory.aws_lb_target_group.api_supervisor
  override_during = plan
  values          = { arn = "arn:aws:elasticloadbalancing:eu-central-1:123456789012:targetgroup/aif-api-9345/0000000000000004" }
}

override_resource {
  target          = module.ai_factory.aws_lb_target_group.http
  override_during = plan
  values          = { arn = "arn:aws:elasticloadbalancing:eu-central-1:123456789012:targetgroup/aif-http/0000000000000005" }
}

override_resource {
  target          = module.ai_factory.aws_lb_target_group.https
  override_during = plan
  values          = { arn = "arn:aws:elasticloadbalancing:eu-central-1:123456789012:targetgroup/aif-https/0000000000000006" }
}

override_resource {
  target          = module.ai_factory.aws_lb_target_group.admin_kube_api
  override_during = plan
  values          = { arn = "arn:aws:elasticloadbalancing:eu-central-1:123456789012:targetgroup/aif-admin-6443/0000000000000007" }
}

override_resource {
  target          = module.ai_factory.aws_s3_bucket.build
  override_during = plan
  values          = { id = "dummy-build-bucket-000000" }
}

override_resource {
  target          = module.ai_factory.time_static.created
  override_during = plan
  values          = { rfc3339 = "2026-11-19T12:34:56Z" }
}

variables {
  region                        = "eu-central-1"
  admin_cidrs                   = ["198.51.100.0/24"]
  root_password_hash            = "$6$DUMMYSALT$ROOTDUMMYHASHROOTDUMMYHASHROOTDUMMYHASHROOTDUMMYHASHROOTDUMMYHASH0"
  node_user_password_hash       = "$6$DUMMYSALT$NODEDUMMYHASHNODEDUMMYHASHNODEDUMMYHASHNODEDUMMYHASHNODEDUMMYHASH0"
  ssh_authorized_keys           = ["ssh-ed25519 AAAADUMMY test"]
  appco_username                = "DUMMY-APPCO-USER"
  appco_password                = "DUMMY-APPCO-PASSWORD"
  suse_registry_username        = "DUMMY-REGCODE"
  suse_registry_password        = "DUMMY-REGISTRY-PASSWORD"
  nvidia_api_key                = "DUMMY-NVIDIA-API-KEY"
  security_join_token           = "00000000-0000-4000-8000-000000000000"
  observability_bootstrap_token = "DUMMY-BOOTSTRAP-TOKEN"
  observability_ca_pem          = "-----BEGIN CERTIFICATE-----\nDUMMY\n-----END CERTIFICATE-----\n"
  observability_license_key     = "DUMMY-LICENSE"
}

run "shape_plans" {
  command = plan
}
