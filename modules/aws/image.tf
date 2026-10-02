# Raw image in S3 -> EBS snapshot -> AMI. The jumphost (build.tf) only uploads
# the raw; Terraform owns the rest, so destroy removes the snapshot and AMI.
# var.image_id skips the chain; an image pinned that way must not be one this
# module owns, or destroy deregisters it. See docs/decisions/002-aws-factory-hooks.md.

locals {
  raw_image_key = "images/${local.ami_name}.raw"

  # deploy_nodes = false still builds the image.
  build_ami = var.image_id == null
}

# The vmimport role's inline policy must exist before the import reads the raw.
resource "aws_ebs_snapshot_import" "ai_factory" {
  count = local.build_ami ? 1 : 0

  role_name = local.vmimport_role_name

  disk_container {
    format = "RAW"

    user_bucket {
      s3_bucket = aws_s3_bucket.build.id
      s3_key    = local.raw_image_key
    }
  }

  depends_on = [
    terraform_data.raw_ready,
    aws_iam_role_policy.vmimport,
  ]

  timeouts {
    create = "60m"
  }

  tags = merge(local.common_tags, {
    Name              = local.ami_name
    "elemental-role"  = "image"
    "elemental-build" = module.elemental_config.build_id
  })

  # Workaround (docs/workarounds.md): VM Import sets its own snapshot
  # description and the attribute forces replacement, so every later plan
  # would replace the snapshot, the AMI and every node.
  lifecycle {
    ignore_changes = [description]
  }
}

resource "aws_ami" "ai_factory" {
  count = local.build_ami ? 1 : 0

  name                = local.ami_name
  architecture        = "x86_64"
  virtualization_type = "hvm"
  ena_support         = true

  # The raw carries an ESP only, no BIOS boot partition.
  boot_mode    = "uefi"
  imds_support = "v2.0"

  root_device_name = "/dev/xvda"

  ebs_block_device {
    device_name = "/dev/xvda"
    snapshot_id = aws_ebs_snapshot_import.ai_factory[0].id

    # The snapshot's size as EC2 reports it, not image_disk_size (a "8G" string).
    volume_size           = aws_ebs_snapshot_import.ai_factory[0].volume_size
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = merge(local.common_tags, {
    Name              = local.ami_name
    "elemental-role"  = "image"
    "elemental-build" = module.elemental_config.build_id
  })
}
