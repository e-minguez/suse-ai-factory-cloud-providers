# Two roles, each scoped to this cluster's resources where a resource-level
# condition exists. Cluster nodes get no instance profile: they call no AWS API.
# With vmimport_role_name and jumphost_instance_profile_name set, nothing is
# created here and the pre-created role and profile are looked up instead.

locals {
  create_iam = var.vmimport_role_name == null

  vmimport_role_name = local.create_iam ? aws_iam_role.vmimport[0].name : data.aws_iam_role.vmimport[0].name
  jumphost_profile   = local.create_iam ? aws_iam_instance_profile.jumphost[0].name : data.aws_iam_instance_profile.jumphost[0].name
}

data "aws_iam_role" "vmimport" {
  count = local.create_iam ? 0 : 1

  name = var.vmimport_role_name
}

data "aws_iam_instance_profile" "jumphost" {
  count = local.create_iam ? 0 : 1

  name = var.jumphost_instance_profile_name
}

# --- vmimport: assumed by the snapshot import service to read the raw image ---

data "aws_iam_policy_document" "vmimport_trust" {
  count = local.create_iam ? 1 : 0

  statement {
    sid     = "AllowVmieToAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vmie.amazonaws.com"]
    }

    # The import service always presents the external ID "vmimport", whatever
    # the role is named, so the condition value is that literal string.
    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = ["vmimport"]
    }
  }
}

resource "aws_iam_role" "vmimport" {
  count = local.create_iam ? 1 : 0

  name               = "${var.cluster_name}-vmimport"
  assume_role_policy = data.aws_iam_policy_document.vmimport_trust[0].json

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-vmimport"
    "elemental-role" = "iam"
  })
}

data "aws_iam_policy_document" "vmimport" {
  count = local.create_iam ? 1 : 0

  statement {
    sid       = "BucketDiscovery"
    effect    = "Allow"
    actions   = ["s3:GetBucketLocation", "s3:ListBucket"]
    resources = [aws_s3_bucket.build.arn]
  }

  # images/* only: config/* holds the AI Factory credentials.
  statement {
    sid       = "ReadRawImages"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.build.arn}/images/*"]
  }

  # The import's own EC2 operations act on objects that do not exist yet or
  # take no ARN, so they cannot be narrowed below "*".
  statement {
    sid    = "Ec2ImportOperations"
    effect = "Allow"
    actions = [
      "ec2:ModifySnapshotAttribute",
      "ec2:CopySnapshot",
      "ec2:RegisterImage",
      "ec2:Describe*",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "vmimport" {
  count = local.create_iam ? 1 : 0

  name   = "${var.cluster_name}-vmimport"
  role   = aws_iam_role.vmimport[0].id
  policy = data.aws_iam_policy_document.vmimport[0].json
}

# --- jumphost: the identity the factory script runs as (build.tf) -------------

data "aws_iam_policy_document" "jumphost_trust" {
  count = local.create_iam ? 1 : 0

  statement {
    sid     = "AllowEc2ToAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "jumphost" {
  count = local.create_iam ? 1 : 0

  name               = "${var.cluster_name}-jumphost"
  assume_role_policy = data.aws_iam_policy_document.jumphost_trust[0].json

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-jumphost"
    "elemental-role" = "iam"
  })
}

data "aws_iam_policy_document" "jumphost" {
  count = local.create_iam ? 1 : 0

  # A LIST rather than a HEAD for the existence check: a HEAD on a missing key
  # returns 403 under a prefix condition (docs/decisions/002-aws-factory-hooks.md).
  statement {
    sid       = "ListBucketImagesPrefix"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.build.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["images/*"]
    }
  }

  # The raw image is the only output. No s3:DeleteObject: the bucket lifecycle
  # rule expires it after the import. No EC2 access at all.
  statement {
    sid    = "WriteRawImages"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:AbortMultipartUpload",
    ]
    resources = ["${aws_s3_bucket.build.arn}/images/*"]
  }
}

resource "aws_iam_role_policy" "jumphost" {
  count = local.create_iam ? 1 : 0

  name   = "${var.cluster_name}-jumphost"
  role   = aws_iam_role.jumphost[0].id
  policy = data.aws_iam_policy_document.jumphost[0].json
}

resource "aws_iam_instance_profile" "jumphost" {
  count = local.create_iam ? 1 : 0

  name = "${var.cluster_name}-jumphost"
  role = aws_iam_role.jumphost[0].name

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-jumphost"
    "elemental-role" = "iam"
  })
}
