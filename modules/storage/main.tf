data "aws_caller_identity" "current" {}

# Customer-managed key for the data volume, rather than the default aws/ebs key
# a bare `encrypted = true` would pick.
#
# cross_account ONLY, and gated rather than always-on for a reason worth
# spelling out. aws/ebs is an AWS-managed key whose policy is immutable and
# therefore cannot be shared with another account; AWS refuses to copy a snapshot
# the destination account cannot decrypt; so a volume on aws/ebs cannot be backed
# up cross-account by any mechanism. That makes the CMK unavoidable *here* and
# pointless everywhere else -- local, cross_region and disabled all work fine on
# aws/ebs, and creating this key for them would bill $1/mo for nothing.
#
# The gate also bounds the pain. kms_key_id is ForceNew, so naming this key
# unconditionally would plan a REPLACE of the data volume in every existing
# deployment -- which prevent_destroy then (correctly) refuses, leaving a repo
# whose plan errors until a re-key nobody asked for. Gated, only the deployment
# that opts into cross_account hits that, and it needs the re-key anyway:
# terraform apply -target this key, scripts/azmove.sh rekey, adopt, apply. See
# docs/cross-account-backup.md (Re-key the data volume).
#
# Root full-access delegates authorization to IAM, matching bootstrap/kms.tf.
data "aws_iam_policy_document" "data_key" {
  count = local.backup_cross_account ? 1 : 0

  statement {
    sid       = "RootFullAccess"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  # The destination account has to decrypt the snapshot to copy it into its own
  # vault, and re-encrypt it under its own key.
  #
  # Read-shaped, never kms:* -- the backup account copies from us, it does not
  # administer our keys. It must never be able to schedule this key for
  # deletion.
  #
  # Spelled out rather than kms:GenerateDataKey* / kms:ReEncrypt*, because the
  # wildcards are wider than they look: GenerateDataKey* also grants
  # GenerateDataKeyPair and GenerateDataKeyPairWithoutPlaintext, which are
  # asymmetric-keypair operations that cannot occur in a snapshot copy. Access
  # Analyzer reports the expanded set, which is how the over-grant surfaced.
  statement {
    sid    = "BackupAccountCopySnapshot"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:ReEncryptFrom",
      "kms:ReEncryptTo",
      "kms:GenerateDataKey",
      "kms:GenerateDataKeyWithoutPlaintext",
    ]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.backup.account_id}:root"]
    }
  }

  # CreateGrant is the one that looks alarming and is required: AWS Backup
  # creates grants on the caller's behalf to run a copy job. GrantIsForAWSResource
  # confines it to grants AWS services create for themselves, so it is not usable
  # as a general-purpose escalation.
  statement {
    sid       = "BackupAccountCreateGrant"
    effect    = "Allow"
    actions   = ["kms:CreateGrant"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.backup.account_id}:root"]
    }
    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }
}

resource "aws_kms_key" "data" {
  count = local.backup_cross_account ? 1 : 0

  description             = "Encrypts the gramps-data EBS volume"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.data_key[0].json

  tags = {
    Name = "gramps-data"
  }
}

resource "aws_kms_alias" "data" {
  count         = local.backup_cross_account ? 1 : 0
  name          = "alias/gramps-data"
  target_key_id = aws_kms_key.data[0].key_id
}

resource "aws_ebs_volume" "this" {
  availability_zone = var.az
  size              = var.data_volume_gib
  type              = "gp3"
  encrypted         = true
  snapshot_id       = var.data_volume_snapshot_id

  # null outside cross_account, which for this Optional+Computed attribute means
  # "whatever the volume already uses" -- so a deployment that never leaves the
  # account keeps its aws/ebs volume with no diff, and dropping back out of
  # cross_account does not plan to un-key a volume either.
  kms_key_id = local.backup_cross_account ? aws_kms_key.data[0].arn : null

  # Persistent selects nothing (AWS Backup names this volume's ARN outright in
  # backup.tf). Kept because azmove.sh sets it on restored volumes and it
  # documents which of the two attached volumes is the irreplaceable one.
  tags = {
    Name       = "gramps-data"
    Persistent = "true"
    Project    = "gramps-web"
  }

  lifecycle {
    prevent_destroy = true
  }
}

locals {
  # Explicit name wins (pre-existing deployments); otherwise derive a name
  # that is unique per account without configuration.
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

# TLS-only. Same control as the audit log bucket; applied to every bucket in the
# estate rather than just that one.
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
# volume (aws_kms_key.data). A CMK here bought only a key policy and rotation
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
  # this rule. See the periodic-vs-continuous note in backup.tf.
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
