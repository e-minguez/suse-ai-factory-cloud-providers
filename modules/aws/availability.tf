# Plan-time preflight: per-zone instance-type offerings. The input checks are
# preconditions on aws_vpc.this (network.tf).

locals {
  # One (instance_type, zone) pair per node placed, plus the jumphost while an image is built.
  node_type_az_pairs = var.deploy_nodes ? [
    for n in local.cluster_nodes : {
      instance_type = n.instance_type
      az            = local.az_names[n.az_index]
    }
  ] : []

  jumphost_type_az_pairs = local.build_ami ? [{
    instance_type = local.jumphost_instance_type
    az            = local.az_names[0]
  }] : []

  checked_type_az_map = {
    for pair in distinct(concat(local.node_type_az_pairs, local.jumphost_type_az_pairs)) :
    "${pair.instance_type}@${pair.az}" => pair
  }
}

# location_type = "availability-zone": a type can be offered in a region and
# absent from the zone a node is placed in.
data "aws_ec2_instance_type_offerings" "this" {
  for_each = local.checked_type_az_map

  filter {
    name   = "instance-type"
    values = [each.value.instance_type]
  }

  filter {
    name   = "location"
    values = [each.value.az]
  }

  location_type = "availability-zone"

  lifecycle {
    postcondition {
      condition     = length(self.instance_types) > 0
      error_message = "Instance type ${each.value.instance_type} is not offered in ${each.value.az} (region ${coalesce(var.region, "unset")}). Choose another type or zone; `aws ec2 describe-instance-type-offerings --location-type availability-zone` lists what is offered."
    }
  }
}
