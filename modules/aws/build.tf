# Build host: builds the raw image and stays as SSH bastion into the private
# nodes. Public subnet and public IP; skipped when image_id is set.

# openSUSE Leap 16 x86_64, an AWS Marketplace image: the account must accept
# the listing terms once, or the apply fails with OptInRequired. Set
# jumphost_image to use a different AMI.
data "aws_ami" "jumphost" {
  count = local.build_ami && var.jumphost_image == null ? 1 : 0

  most_recent = true
  owners      = ["679593333241"] # aws-marketplace, openSUSE project's publisher
  # Workaround (docs/workarounds.md): current Leap 16 images carry a
  # deprecation time; deprecated images still launch.
  include_deprecated = true

  filter {
    name   = "name"
    values = ["openSUSE-Leap-16*"]
  }

  # The same publish run ships an arm64 image under the same name prefix.
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  jumphost_ami_id = var.jumphost_image != null ? var.jumphost_image : try(data.aws_ami.jumphost[0].id, null)

  # Build-id-, bucket- and key-dependent values are placeholders in the shared
  # script, so its script_hash (a build_hash input) is static. The stripped
  # script is what ships in user_data.
  build_id_placeholder = "@@BUILD_ID@@"
  bucket_placeholder   = "@@BUCKET@@"
  raw_key_placeholder  = "images/${var.cluster_name}-${local.build_id_placeholder}.raw"

  factory_script = replace(
    replace(
      replace(module.image_factory.script_stripped, local.raw_key_placeholder, local.raw_image_key),
      local.bucket_placeholder, aws_s3_bucket.build.id
    ),
    local.build_id_placeholder, module.elemental_config.build_id
  )

  # Files written by cloud-init, each gzip+base64. Config files carry credentials.
  jumphost_files = concat(
    [{
      path    = "/opt/image-factory.sh"
      mode    = "0700"
      content = base64gzip(local.factory_script)
    }],
    [
      for name in module.elemental_config.elemental_file_names : {
        path    = "${local.config_dir}/${name}"
        mode    = "0600"
        content = base64gzip(module.elemental_config.elemental_files[name])
      }
    ]
  )

  # Comment lines (`# ` prefix) are dropped; "#cloud-config" stays.
  jumphost_user_data = replace(
    templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
      log_file            = "/var/log/elemental-factory.log"
      ssh_authorized_keys = var.ssh_authorized_keys
      jumphost_username   = var.jumphost_username
      files               = local.jumphost_files
    }),
    "/(?m)^[ \\t]*# .*\\n/", ""
  )
}

resource "aws_instance" "jumphost" {
  count = local.build_ami ? 1 : 0

  ami = local.jumphost_ami_id
  # The Marketplace listing restricts instance types (7th-generation types are
  # rejected with UnsupportedOperation); the default is the newest one it allows.
  instance_type = local.jumphost_instance_type

  subnet_id                   = aws_subnet.public[0].id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.jumphost.id]
  iam_instance_profile        = local.jumphost_profile

  user_data = local.jumphost_user_data
  # EC2 reads user_data on first boot only.
  user_data_replace_on_change = true

  root_block_device {
    volume_size = local.jumphost_disk_size_gb
    volume_type = "gp3"
    encrypted   = true

    tags = merge(local.common_tags, {
      Name             = "${var.cluster_name}-jumphost-root"
      "elemental-role" = "jumphost"
    })
  }

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-jumphost"
    "elemental-role" = "jumphost"
  })

  # The policy must exist when the factory script uploads seconds after boot;
  # the instance type must be offered in the zone (availability.tf).
  depends_on = [
    aws_iam_role_policy.jumphost,
    data.aws_ec2_instance_type_offerings.this,
  ]

  lifecycle {
    precondition {
      # EC2 hard limit on user_data; nonsensitive() on the length only.
      condition     = length(local.jumphost_user_data) <= 16384
      error_message = "Rendered jumphost user_data is ${nonsensitive(length(local.jumphost_user_data))} bytes, over EC2's 16384-byte limit. The script and config are inline, gzipped; a large ssh_authorized_keys or config tree is the likely cause."
    }
  }
}

# Jumphost and build hosts in state, for scripts/lib/ssh.sh during the apply:
# the outputs reach the state file only after the AMI exists.
resource "terraform_data" "build_access" {
  count = local.build_ami ? 1 : 0

  input = {
    build_id     = module.elemental_config.build_id
    jumphost     = local.jumphost_access
    build_status = local.build_status_value
  }
}

# Blocks the apply until the raw image is in S3 (90 minutes at most). Replaced
# on every new ami_name so a rebuild waits again.
resource "terraform_data" "raw_ready" {
  count = local.build_ami ? 1 : 0

  depends_on = [aws_instance.jumphost]

  triggers_replace = [local.ami_name]

  provisioner "local-exec" {
    command = "${path.module}/scripts/wait-for-raw.sh"
    environment = {
      BUCKET          = aws_s3_bucket.build.id
      RAW_KEY         = local.raw_image_key
      AWS_REGION      = var.region
      TIMEOUT_SECONDS = 5400
      POLL_SECONDS    = 30
    }
  }
}

module "image_factory" {
  source = "../image-factory"

  elemental_image = var.elemental_image
  build_id        = local.build_id_placeholder
  config_dir      = local.config_dir
  log_file        = "/var/log/elemental-factory.log"
  state_dir       = "/var/lib/elemental-factory"
  extra_packages  = ["unzip"]

  hook_pre_build = templatefile("${path.module}/templates/hook-pre-build.sh.tftpl", {
    region = coalesce(var.region, "unset") # required (network.tf precondition); keeps tflint off null
    bucket = local.bucket_placeholder
  })
  hook_is_already_built = templatefile("${path.module}/templates/hook-is-already-built.sh.tftpl", {
    bucket  = local.bucket_placeholder
    raw_key = local.raw_key_placeholder
  })
  hook_deliver_raw = "aws s3 cp \"$1\" \"s3://${local.bucket_placeholder}/${local.raw_key_placeholder}\""
}
