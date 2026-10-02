# Build bucket: holds only the raw image the jumphost uploads (images/), which
# aws_ebs_snapshot_import reads. Instances read nothing from it: the jumphost
# gets its script and config inline in user_data (build.tf).

# Bucket names are global; the random suffix avoids collisions between clusters.
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "build" {
  bucket = "${var.cluster_name}-build-${random_id.bucket_suffix.hex}"

  # Destroy must not be blocked by leftovers in images/.
  force_destroy = true

  tags = merge(local.common_tags, {
    Name             = "${var.cluster_name}-build"
    "elemental-role" = "image"
  })
}

resource "aws_s3_bucket_public_access_block" "build" {
  bucket = aws_s3_bucket.build.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# SSE-S3, not SSE-KMS: KMS would need extra grants for the vmimport role.
resource "aws_s3_bucket_server_side_encryption_configuration" "build" {
  bucket = aws_s3_bucket.build.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_ownership_controls" "build" {
  bucket = aws_s3_bucket.build.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# The lifecycle rule is the cleanup of the raw image (the jumphost cannot delete
# it): expiry after 1 day, disabled by keep_build_artifacts.
resource "aws_s3_bucket_lifecycle_configuration" "build" {
  bucket = aws_s3_bucket.build.id

  rule {
    id     = "expire-raw-images"
    status = var.keep_build_artifacts ? "Disabled" : "Enabled"

    filter {
      prefix = "images/"
    }

    expiration {
      days = 1
    }
  }
}
