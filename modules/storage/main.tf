data "aws_caller_identity" "current" {}

# Volume, its key and AWS Backup live in keel's data-volume. Names are pinned to
# the ones this stack created before the module existed, so adoption renames
# nothing. The vaults use a customer-managed key because the media bucket's S3
# recovery points are re-encrypted under it and must be readable cross-account.
module "data_volume" {
  source = "git::https://github.com/kjiwa/terraform-aws-keel.git//modules/data-volume?ref=v0.2.0"

  name_prefix = "gramps-web"
  volume_name = "gramps-data"
  volume_tags = {
    Project = "gramps-web"
  }
  az          = var.az
  size_gib    = var.data_volume_gib
  snapshot_id = var.data_volume_snapshot_id

  backup        = var.backup
  backup_region = var.backup_region
  vault_kms     = "cmk"

  extra_backup_resource_arns = [aws_s3_bucket.media.arn]
}

locals {
  # An explicit name wins; otherwise derive one unique per account.
  media_bucket_name = (
    var.media_bucket_name != ""
    ? var.media_bucket_name
    : "gramps-web-media-${data.aws_caller_identity.current.account_id}"
  )
}

resource "aws_s3_bucket" "media" {
  bucket = local.media_bucket_name

  tags = {
    Name = "gramps-media"
  }

  # Holds the photo/document originals: irreplaceable, same as the data volume.
  # Guards `terraform destroy` and, more usefully, a media_bucket_name typo --
  # which would otherwise plan a replacement.
  lifecycle {
    prevent_destroy = true
  }
}

# TLS-only.
data "aws_iam_policy_document" "media" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.media.arn, "${aws_s3_bucket.media.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "media" {
  bucket = aws_s3_bucket.media.id
  policy = data.aws_iam_policy_document.media.json
}

resource "aws_s3_bucket_ownership_controls" "media" {
  bucket = aws_s3_bucket.media.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "media" {
  bucket = aws_s3_bucket.media.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# The media bucket is SSE-S3, not a customer-managed key like the EBS data
# volume (the data-volume module's key). A CMK here bought only a key policy and rotation
# schedule an auditor could point at, plus crypto-shred by deleting the key --
# it never gated cross-account backup: AWS Backup reads objects through the
# backup role and re-encrypts them under the vault's key regardless of the
# source object's encryption, and S3 recovery points are re-encrypted under
# the local vault's key at backup time. Only the EBS volume genuinely needs a
# CMK to leave the account.
resource "aws_s3_bucket_server_side_encryption_configuration" "media" {
  bucket = aws_s3_bucket.media.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "media" {
  bucket = aws_s3_bucket.media.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "media" {
  bucket = aws_s3_bucket.media.id

  depends_on = [aws_s3_bucket_versioning.media]

  rule {
    id     = "expire-noncurrent"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    # scripts/media.sh gc plain-deletes orphaned objects, which on a versioned
    # bucket leaves a delete marker rather than removing anything -- that's
    # the point, it's the 90-day undo window paired with the noncurrent
    # expiration above. But once its lone noncurrent version ages out, an
    # untouched delete marker is pure clutter with nothing left to mark.
    # This sweeps those.
    expiration {
      expired_object_delete_marker = true
    }
  }

  # Originals are write-once, read-rarely (the app caches thumbnails on EBS).
  # Intelligent-Tiering auto-archives cold objects (~45% off Standard after
  # 30/90 days idle) with no retrieval fee on the instant-access tiers, so
  # viewing an old photo costs the same as Standard. Monitoring fee is
  # $0.0025/1k objects/mo; net positive for multi-MB media.
  #
  # This pulls against AWS Backup, honestly: reading an INT object counts as
  # access and bumps it back to Frequent Access, so the first (full) backup
  # un-archives the whole corpus. Only changed objects are read after that, so
  # it re-cools and the steady state is unaffected -- and at this corpus size the
  # whole effect is sub-cent either way. It would matter at scale; the answer
  # there is continuous backups (which read only what changed), not dropping
  # this rule. See the periodic-vs-continuous note in keel's data-volume backup.tf.
  rule {
    id     = "media-intelligent-tiering"
    status = "Enabled"

    filter {}

    transition {
      days          = 0
      storage_class = "INTELLIGENT_TIERING"
    }
  }
}
