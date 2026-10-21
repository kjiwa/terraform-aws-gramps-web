# Off-site backup of the irreplaceable data -- the EBS data volume (tree DB,
# search index, users, secret) and the S3 media bucket (photo/document
# originals) -- through AWS Backup. One plan covers both. backup.mode drives it:
#
#   local        - daily recovery points in a vault in this account/region only
#   cross_region - also copy each recovery point to a vault this module creates
#                  in backup_region (region-failure DR, same account)
#   cross_account - also copy each recovery point to a vault another account in
#                  the org owns (blast-radius isolation; point it at a region
#                  other than the primary and it subsumes cross_region)
#   disabled     - no scheduled backups
#
# Only cross_account produces a copy this account cannot delete -- every other
# mode leaves all copies owned by the one account whose loss would take them
# all. Why that matters, and the ordered, gated migration into it (do not
# improvise it): docs/cross-account-backup.md.
#
# NOT free, and small enough to be worth naming: a CMK per vault at ~$1/mo (see
# the key comments for why each one is unavoidable). Storage stays in cents --
# cross-account copies are incremental after the first full copy, and AWS Backup
# prices EBS recovery points the same as plain snapshots.

locals {
  backup_enabled       = var.backup.mode != "disabled"
  backup_offsite       = contains(["cross_region", "cross_account"], var.backup.mode)
  backup_cross_region  = var.backup.mode == "cross_region"
  backup_cross_account = var.backup.mode == "cross_account"

  # Where copies go. cross_region: a vault this module owns in backup_region.
  # cross_account: a vault the destination account owns, whose ARN is
  # CONSTRUCTED rather than passed in -- unlike a KMS key ARN (random UUID), a
  # vault ARN is fully determined by account + region + name, so the contract
  # with keel's backup-vault-account module is the name and nothing has to be pasted into
  # tfvars after the fact. If the name drifts, copy jobs fail at runtime; there
  # is no plan-time check for a vault in another account.
  backup_copy_vault_arn = (
    local.backup_cross_region ? one(aws_backup_vault.replica[*].arn) :
    local.backup_cross_account ? "arn:aws:backup:${var.backup_region}:${var.backup.account_id}:backup-vault:${var.backup.dest_vault_name}" :
    null
  )

  # 0 means "same as local". The split exists because the two copies answer
  # different questions: the local vault is the fast restore path (restoring
  # from the destination account means copying back first), the remote one is
  # the one that has to still be there after a bad month.
  backup_remote_retention_days = (
    var.backup.remote_retention_days > 0
    ? var.backup.remote_retention_days
    : var.backup.retention_days
  )

  # Every AWS Backup managed policy this role needs. The EBS and S3 halves are
  # separate policies, and the Restores ones are not optional dead weight: a
  # vault you cannot restore from is not a backup. ForBackup also carries
  # backup:CopyFromBackupVault + backup:CopyIntoBackupVault, which the copy job
  # needs on the identity side (the destination vault's resource policy is only
  # half of a cross-account call).
  #
  # Mind the paths: the two S3 policies live at the policy root while the other
  # two are under service-role/, despite the matching names. AWS is simply
  # inconsistent here. Guessing by pattern gets you a 404 NoSuchEntity at apply
  # time, not a plan error -- these ARNs are opaque strings to Terraform. Verify
  # with `aws iam list-policies --scope AWS --query "Policies[?PolicyName=='X']"`
  # before editing this list.
  backup_role_policies = local.backup_enabled ? toset([
    "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup",
    "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores",
    "arn:aws:iam::aws:policy/AWSBackupServiceRolePolicyForS3Backup",
    "arn:aws:iam::aws:policy/AWSBackupServiceRolePolicyForS3Restore",
  ]) : toset([])

  # Every irreplaceable resource, named outright. Explicit ARNs beat tag
  # selection for a handful of known resources -- "everything tagged
  # Persistent" quietly becomes a different set the first time anything else
  # in the account wears that tag. The tag stays on the volume anyway:
  # azmove.sh sets it on restored volumes, and it documents which volume is
  # the irreplaceable one. Hoisted to a local (rather than inlined on
  # aws_backup_selection.this below) so outputs.backup_resource_count can
  # report its length without a second literal to drift out of sync.
  backup_resources = [aws_ebs_volume.this.arn, aws_s3_bucket.media.arn]
}

# --- Local vault -------------------------------------------------------------
# The plan writes here, and copy_action copies FROM here. A local vault is not a
# style choice you can opt out of: there is no way to have AWS Backup write
# straight to another account. What IS tunable is how long it keeps things --
# see backup.retention_days vs backup.remote_retention_days.

# Customer-managed key for the local vault, rather than the default aws/backup
# key. Needed for S3 specifically: AWS Backup uses an independent encryption
# model for S3, decrypting objects (SSE-S3, in the media bucket's case) at
# backup time and re-encrypting the recovery point under THIS key. The
# destination account has to be able to read that recovery point to copy it,
# and aws/backup is an AWS-managed key whose policy is immutable and cannot be
# shared cross-account.
#
# EBS is the opposite and does not care: AWS Backup stores EBS recovery points
# as native snapshots encrypted with the VOLUME's key, so this key never touches
# them. That asymmetry is why the volume needs its own CMK too (main.tf) --
# giving the vault a CMK does not re-key the snapshots.
data "aws_iam_policy_document" "backup_key" {
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

  # The backup account's half of the traffic in BOTH directions.
  #
  # Outbound (prod -> backup), it reads recovery points out of this vault. Return
  # (backup -> prod), it WRITES: a copy back is re-encrypted under this key, so
  # decrypt alone is not enough.
  #
  # Both halves are load-bearing: the read half is what the outbound direction
  # needs, and the write half is what lets a copy back land here at all (see
  # aws_backup_vault_policy.this below for the timing trap).
  #
  # Deliberately the mirror of SourceAccountCopyIn on the destination key
  # (keel's backup-vault-account module): same actions, opposite direction. The two
  # accounts trust each other to move backups and nothing else -- never kms:*,
  # so neither can disable or schedule deletion of the other's key.
  #
  # Spelled out, not wildcards -- see the twin statement in modules/storage/main.tf
  # (BackupAccountCopySnapshot) for why.
  dynamic "statement" {
    for_each = local.backup_cross_account ? [1] : []
    content {
      sid    = "BackupAccountCopy"
      effect = "Allow"
      actions = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:ReEncryptFrom",
        "kms:ReEncryptTo",
        "kms:GenerateDataKey",
        "kms:GenerateDataKeyWithoutPlaintext",
        "kms:DescribeKey",
      ]
      resources = ["*"]
      principals {
        type        = "AWS"
        identifiers = ["arn:aws:iam::${var.backup.account_id}:root"]
      }
    }
  }

  # AWS Backup creates grants on the caller's behalf to complete a copy job;
  # GrantIsForAWSResource confines this to grants an AWS service makes for
  # itself, so it is not a general-purpose escalation. Separate statement because
  # the condition cannot be attached to only some actions of the one above.
  dynamic "statement" {
    for_each = local.backup_cross_account ? [1] : []
    content {
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
}

resource "aws_kms_key" "backup" {
  count = local.backup_enabled ? 1 : 0

  description             = "Encrypts the gramps-web-backup vault"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.backup_key.json

  tags = {
    Name = "gramps-web-backup"
  }
}

resource "aws_kms_alias" "backup" {
  count         = local.backup_enabled ? 1 : 0
  name          = "alias/gramps-web-backup"
  target_key_id = aws_kms_key.backup[0].key_id
}

resource "aws_backup_vault" "this" {
  count       = local.backup_enabled ? 1 : 0
  name        = "gramps-web-backup"
  kms_key_arn = aws_kms_key.backup[0].arn

  tags = {
    Name = "gramps-web-backup"
  }
}

# The return path. AWS Backup cannot restore across accounts, so recovering INTO
# this account means copying the recovery point back here and restoring it. This
# policy is the half that makes such a copy admissible: the mirror of
# aws_backup_vault_policy.replica in keel's backup-vault-account module, and just as
# narrow. CopyIntoBackupVault only -- the backup account can hand a copy back and
# can do nothing else here, not read our other recovery points, delete them, or
# enumerate the vault. The trust is one action wide in each direction.
#
# Verified working, but slow: a copy back runs 4-6 HOURS against 2-5 minutes
# outbound, sitting in CREATED with no status message throughout, so it is
# indistinguishable from hung. Do not conclude it is broken from a short poll.
# Restoring INSIDE the backup account stays the faster path, and is what the
# disaster this design guards against would call for anyway; this is for the
# narrower case where the workload account is healthy and the data is not.
# Measurements: docs/cross-account-backup.md.
#
# cross_account only: nothing else has another account to grant.
data "aws_iam_policy_document" "backup_vault" {
  count = local.backup_cross_account ? 1 : 0

  statement {
    sid       = "AllowBackupAccountCopyBack"
    effect    = "Allow"
    actions   = ["backup:CopyIntoBackupVault"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.backup.account_id}:root"]
    }
  }
}

resource "aws_backup_vault_policy" "this" {
  count             = local.backup_cross_account ? 1 : 0
  backup_vault_name = aws_backup_vault.this[0].name
  policy            = data.aws_iam_policy_document.backup_vault[0].json
}

# --- Cross-region destination vault (cross_region only) ----------------------
# cross_account copies into a vault the destination account owns and manages
# (keel's backup-vault-account module), so nothing is created here for it.

resource "aws_kms_key" "backup_replica" {
  count  = local.backup_cross_region ? 1 : 0
  region = var.backup_region

  description             = "Encrypts the gramps-web-backup-replica vault in ${var.backup_region}"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "RootFullAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      }
    ]
  })

  tags = {
    Name = "gramps-web-backup-replica"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "backup_replica" {
  count         = local.backup_cross_region ? 1 : 0
  region        = var.backup_region
  name          = "alias/gramps-web-backup-replica"
  target_key_id = aws_kms_key.backup_replica[0].key_id
}

# prevent_destroy on the vault AND its key: leaving cross_region drops both to
# count 0, and Terraform would schedule the key for deletion (succeeds) while
# failing to delete the non-empty vault -- a half-applied state and copies that
# become unreadable in 30 days. The plan errors instead. To genuinely leave,
# including when migrating to cross_account: delete the recovery points, remove
# these lifecycle blocks, apply. See docs/cross-account-backup.md's
# "Decommission the cross_region replica vault" appendix section.
resource "aws_backup_vault" "replica" {
  count       = local.backup_cross_region ? 1 : 0
  region      = var.backup_region
  name        = "gramps-web-backup-replica"
  kms_key_arn = aws_kms_key.backup_replica[0].arn

  tags = {
    Name = "gramps-web-backup-replica"
  }

  lifecycle {
    prevent_destroy = true
  }
}

# --- Plan --------------------------------------------------------------------

data "aws_iam_policy_document" "backup_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backup" {
  count              = local.backup_enabled ? 1 : 0
  name               = "gramps-web-backup"
  assume_role_policy = data.aws_iam_policy_document.backup_assume.json

  tags = {
    Name = "gramps-web-backup"
  }
}

resource "aws_iam_role_policy_attachment" "backup" {
  for_each   = local.backup_role_policies
  role       = aws_iam_role.backup[0].name
  policy_arn = each.value
}

# One rule on var.backup.schedule (knob documented on the backup variable in
# variables.tf).
#
# Periodic (enable_continuous_backup defaults false), deliberately, though
# continuous is the option that looks better on paper:
#   - Continuous depends on the bucket's EventBridge notification setting, and
#     if that is ever turned off S3 stops publishing events, backups silently
#     stop, and AWS raises NO alarm and fails NO job. A backup with a silent
#     failure mode is worse than a slower one.
#   - Continuous caps retention at 35 days.
# The cost of periodic is that each run rescans the whole bucket, which at ~120
# objects is nothing. Revisit if the corpus reaches ~100k objects, where the
# rescan starts to dominate and continuous+periodic-in-one-vault is the answer.
resource "aws_backup_plan" "this" {
  count = local.backup_enabled ? 1 : 0
  name  = "gramps-web-daily"

  rule {
    rule_name         = "daily-${var.backup.retention_days}d"
    target_vault_name = aws_backup_vault.this[0].name
    schedule          = var.backup.schedule

    lifecycle {
      delete_after = var.backup.retention_days
    }

    # No cold-storage transition: AWS Backup does not support cross-account
    # copies of cold-tier recovery points, and S3 recovery points cannot be
    # tiered at all. Setting it would break the copy for a few cents.
    dynamic "copy_action" {
      for_each = local.backup_offsite ? [1] : []
      content {
        destination_vault_arn = local.backup_copy_vault_arn

        lifecycle {
          delete_after = local.backup_remote_retention_days
        }
      }
    }
  }

  tags = {
    Name = "gramps-web-daily"
  }
}

resource "aws_backup_selection" "this" {
  count        = local.backup_enabled ? 1 : 0
  name         = "gramps-web-irreplaceable"
  iam_role_arn = aws_iam_role.backup[0].arn
  plan_id      = aws_backup_plan.this[0].id

  resources = local.backup_resources
}
