#!/bin/sh
# Getting the data back -- the EBS data volume AND the S3 media bucket -- for
# every path docs/restore.md describes. backup.sh deliberately excludes
# restores; this is where they live.
#
#   ./restore.sh list                        What's in both vaults, both
#                                             resource types (needs
#                                             BACKUP_PROFILE to show the
#                                             off-site one)
#   ./restore.sh local <rp-arn>              Restore from the LOCAL vault,
#                                             into the workload account: EBS
#                                             into the live subnet's AZ, S3
#                                             into a scratch bucket
#   ./restore.sh offsite <rp-arn> [--to-bucket <name>]
#                                             Restore INSIDE the backup
#                                             account, to a scratch volume or
#                                             scratch bucket
#   ./restore.sh copy-back <rp-arn>          Pull an off-site recovery point
#                                             back (4-6h), then restore it
#   ./restore.sh drill                       Prove the cross-account pipeline
#                                             end to end, for BOTH resource
#                                             types; gates locking the
#                                             destination vault
#   ./restore.sh drill-cleanup [manifest]    Remove what `drill` created
#
# Every subcommand that takes a recovery-point ARN reads its ResourceType
# (EBS or S3) off the recovery point itself and branches -- you never have to declare
# which kind it is.
#
# Two accounts, two profiles. AWS_PROFILE selects the workload account, same
# as every other script here; BACKUP_PROFILE (new) selects the backup
# account for offsite, copy-back, drill, and drill-cleanup. There is no
# assume_role anywhere in this repo -- a second account always means a
# second profile. Every ARN this script needs (roles, vaults) is constructed
# from the module's outputs + repo-constant resource names, the same way
# backup.sh and the storage module do -- never by reading the backup account's
# own Terraform state, which is exactly what that account exists to avoid.
#
# What this script does NOT do, by design:
#   - choose which recovery point to restore (`list` informs; you decide)
#   - scripts/azmove.sh adopt or terraform apply -- putting a restored
#     volume into service is a separate, deliberate gate (docs/az-move.md)
#   - delete the live volume or write into the live media bucket (an S3
#     restore always lands in a scratch bucket -- see below)
#   - full EBS content verification. `drill` and `offsite` both restore the
#     volume and confirm only that it reports a positive GiB size (an empty
#     recovery point restores COMPLETED too, so size is not nothing, but it
#     is not a checksum either). The backup account deliberately has no VPC
#     or compute of its own, so byte-for-byte verification is not stood up
#     here -- the S3 half gives content proof (object count + total bytes
#     against the live bucket, no compute needed), which this script
#     automates. To verify the EBS half by hand: `offsite` the volume, attach
#     it to an instance, and diff a checksum manifest.
#
# Restore parameters are not guessable: every recovery point declares what
# it wants (volumeType, volumeSize, encrypted, kmsKeyId for EBS), and EBS's
# availabilityZone always comes back null. This script reads that metadata
# and patches in the AZ (or, for S3, the destination bucket name); see
# restore_metadata in common.sh.
#
# Root: --root DIR, or $GRAMPS_WEB_ROOT, is the Terraform root that
#       instantiates the module (see common.sh). Place it before the subcommand.
# Env:  BACKUP_PROFILE (required for offsite/copy-back/drill/drill-cleanup),
#       FORCE=1 (skip prompts).
# Files: drill writes its manifest, restore-drill-*.json, to the current
#       directory; drill-cleanup reads the newest one there.
set -eu

SCRIPT_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly SCRIPT_DIR

readonly LOG_PREFIX="restore"
# shellcheck source=keel/common.sh
. "$SCRIPT_DIR/keel/common.sh"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

BACKUP_PROFILE="${BACKUP_PROFILE:-}"
readonly BACKUP_PROFILE

# Repo constants -- see backup.sh's own header for why these are constants
# rather than Terraform outputs (a name mismatch fails loudly, not silently).
readonly BACKUP_ROLE_NAME="gramps-web-backup"     # workload account
readonly RESTORE_ROLE_NAME="gramps-web-restore"   # backup account (keel backup-vault-account)
readonly BACKUP_PLAN_NAME="gramps-web-daily"
readonly DRILL_TAG="gramps-web-restore-drill"
# Drill artifacts are throwaway; a short, fixed retention means a failed
# drill-cleanup (an SCP deny -- see "Protecting the backup account with
# SCPs" in docs/cross-account-backup.md -- a transient error, or forgetting
# to run it at all) self-expires in a day instead of riding the full
# production retention window. This is also the reason the drill's preflight
# refuses to run against an already-locked vault: a lock with
# min_retention_days above 1 would reject a 1-day copy outright -- the drill
# can only ever run BEFORE the vault is locked.
readonly DRILL_RETENTION_DAYS=1

# Job polling, same ceilings as backup.sh (the S3 half is the long pole for
# backup/copy) plus restore- and copy-back-specific ones. A copy BACK is
# documented at 4-6 HOURS, sitting in CREATED the whole time with no status
# message -- COPY_BACK_TICKS gives ~7h of headroom above that, and the S3
# half may be slower than an EBS-only copy back.
readonly POLL_SECONDS=15
readonly BACKUP_TICKS=240
readonly COPY_TICKS=80
readonly RESTORE_TICKS=80
readonly COPY_BACK_TICKS=1680
readonly HEARTBEAT_EVERY=8

# --- shared helpers -----------------------------------------------------------

# -> the backup account id from BACKUP_PROFILE's credentials, checked
# against the account in the destination vault ARN. The counterpart to
# common.sh's resolve_account for the second account this script talks to.
resolve_backup_account() {
  require_backup_mode cross_account
  _resolve_backup_account_want="$(dest_account_id)"
  [ -n "$BACKUP_PROFILE" ] ||
    die "BACKUP_PROFILE not set; this needs the backup account's own credentials"
  _resolve_backup_account_got="$(aws_as "$BACKUP_PROFILE" sts get-caller-identity --query Account --output text)" ||
    die "could not read caller identity for BACKUP_PROFILE=$BACKUP_PROFILE"
  [ "$_resolve_backup_account_want" = "$_resolve_backup_account_got" ] ||
    die "wrong account: BACKUP_PROFILE=$BACKUP_PROFILE resolves to $_resolve_backup_account_got, but the stack copies into $_resolve_backup_account_want."
  echo "$_resolve_backup_account_got"
}

# rp_resource_type VAULT RP REGION [PROFILE] -> EBS | S3, read from the
# recovery point itself (describe-recovery-point) rather than asked of the
# operator -- the recovery point already knows.
rp_resource_type() {
  aws_as "${4:-}" backup describe-recovery-point --region "$3" \
    --backup-vault-name "$1" --recovery-point-arn "$2" \
    --query 'ResourceType' --output text
}

# tag_restored_volume REGION VOL NAME [PROFILE]: apply the tags
# start-restore-job's --metadata cannot set. Project=gramps-web is required
# before azmove.sh adopt will accept the volume, and before the instance
# role can AttachVolume at all (modules/compute/iam.tf gates both on
# aws:ResourceTag/Project == gramps-web).
tag_restored_volume() {
  aws_as "${4:-}" ec2 create-tags --region "$1" --resources "$2" \
    --tags Key=Project,Value=gramps-web "Key=Name,Value=$3"
}

# restore_ebs_into_workload RP -> new volume id on stdout, once available.
# Restores from the LOCAL vault ($VAULT, set by the caller) into the live
# subnet's AZ (required for azmove.sh adopt), then tags it so adopt will
# take it. Shared by `local` and `copy-back` -- both end the same way once
# the recovery point sits in the local vault. Callers set ROLE and VAULT
# first.
restore_ebs_into_workload() {
  _restore_ebs_into_workload_rp="$1"
  _restore_ebs_into_workload_az="$(aws ec2 describe-volumes --region "$REGION" \
    --volume-ids "$(tf_output ebs_volume_id)" \
    --query 'Volumes[0].AvailabilityZone' --output text)"

  _restore_ebs_into_workload_meta="$(restore_metadata "$VAULT" "$_restore_ebs_into_workload_rp" "$REGION" "$_restore_ebs_into_workload_az")"
  _restore_ebs_into_workload_job="$(aws backup start-restore-job --region "$REGION" \
    --recovery-point-arn "$_restore_ebs_into_workload_rp" --iam-role-arn "$ROLE" \
    --resource-type EBS --metadata "$_restore_ebs_into_workload_meta" --query 'RestoreJobId' --output text)"
  log "Restore job started: $_restore_ebs_into_workload_job"
  poll_job "Restore" "$RESTORE_TICKS" "$_restore_ebs_into_workload_job" restore "$REGION"

  _restore_ebs_into_workload_vol="$(aws backup describe-restore-job --region "$REGION" --restore-job-id "$_restore_ebs_into_workload_job" \
    --query 'CreatedResourceArn' --output text | awk -F/ '{print $NF}')"
  tag_restored_volume "$REGION" "$_restore_ebs_into_workload_vol" gramps-data
  log "Restored volume: $_restore_ebs_into_workload_vol (tagged Project=gramps-web, in $_restore_ebs_into_workload_az -- the live subnet's AZ)"
  echo "$_restore_ebs_into_workload_vol"
}

# --- scratch S3 destination ---------------------------------------------------
#
# An S3 restore needs a destination bucket with versioning enabled -- the job
# fails outright otherwise -- and the backup account has none
# (keel backup-vault-account provisions a vault, a key, and a role, nothing else).

# The Backup OU's SCP denies s3:DeleteBucket and s3:DeleteObjectVersion, so
# the bucket is one stable name per account and region that empties itself by
# lifecycle expiry (not subject to the SCP) instead of being deleted.
SCRATCH_LIFECYCLE='{"Rules":[
  {"ID":"expire-objects","Status":"Enabled","Filter":{},
   "Expiration":{"Days":1},
   "NoncurrentVersionExpiration":{"NoncurrentDays":1},
   "AbortIncompleteMultipartUpload":{"DaysAfterInitiation":1}},
  {"ID":"expire-delete-markers","Status":"Enabled","Filter":{},
   "Expiration":{"ExpiredObjectDeleteMarker":true}}]}'

# create_scratch_bucket PROFILE REGION -> the account's scratch bucket name on
# stdout, once ready (exists, versioning on, public access blocked, lifecycle
# applied, and empty -- S3 restores skip existing keys, so a leftover object
# could make a restore or drill pass falsely).
create_scratch_bucket() {
  _create_scratch_bucket_bucket=""
  _create_scratch_bucket_profile="$1"
  _create_scratch_bucket_region="$2"
  _create_scratch_bucket_account="$(aws_as "$_create_scratch_bucket_profile" sts get-caller-identity --query 'Account' --output text)" ||
    die "could not read caller identity for the scratch bucket name."
  _create_scratch_bucket_bucket="gramps-web-restore-${_create_scratch_bucket_account}-${_create_scratch_bucket_region}"

  _create_scratch_bucket_head_err=0
  _create_scratch_bucket_head_out="$(aws_as "$_create_scratch_bucket_profile" s3api head-bucket --bucket "$_create_scratch_bucket_bucket" 2>&1)" || _create_scratch_bucket_head_err=1
  if [ "$_create_scratch_bucket_head_err" = 1 ]; then
    case "$_create_scratch_bucket_head_out" in
      *"(404)"* | *"Not Found"*) ;;
      *) die "could not check scratch bucket $_create_scratch_bucket_bucket: $_create_scratch_bucket_head_out" ;;
    esac
    log "Creating scratch bucket $_create_scratch_bucket_bucket ($_create_scratch_bucket_region)..."
    # us-east-1 is the one region create-bucket rejects a LocationConstraint
    # for -- it is implicit there and an explicit one is a 400.
    if [ "$_create_scratch_bucket_region" = "us-east-1" ]; then
      aws_as "$_create_scratch_bucket_profile" s3api create-bucket --bucket "$_create_scratch_bucket_bucket" --region "$_create_scratch_bucket_region" >/dev/null
    else
      aws_as "$_create_scratch_bucket_profile" s3api create-bucket --bucket "$_create_scratch_bucket_bucket" --region "$_create_scratch_bucket_region" \
        --create-bucket-configuration "LocationConstraint=$_create_scratch_bucket_region" >/dev/null
    fi
  fi
  aws_as "$_create_scratch_bucket_profile" s3api put-bucket-versioning --bucket "$_create_scratch_bucket_bucket" --region "$_create_scratch_bucket_region" \
    --versioning-configuration Status=Enabled
  aws_as "$_create_scratch_bucket_profile" s3api put-public-access-block --bucket "$_create_scratch_bucket_bucket" --region "$_create_scratch_bucket_region" \
    --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws_as "$_create_scratch_bucket_profile" s3api put-bucket-lifecycle-configuration --bucket "$_create_scratch_bucket_bucket" --region "$_create_scratch_bucket_region" \
    --lifecycle-configuration "$SCRATCH_LIFECYCLE" ||
    die "could not set the lifecycle rule on $_create_scratch_bucket_bucket. It is what empties the scratch bucket
between restores; check that no policy (such as the Backup OU's SCP) denies
s3:PutLifecycleConfiguration there."

  _create_scratch_bucket_leftover="$(aws_as "$_create_scratch_bucket_profile" s3api list-object-versions --bucket "$_create_scratch_bucket_bucket" --region "$_create_scratch_bucket_region" \
    --max-items 1 --query '(Versions[0].Key || DeleteMarkers[0].Key)' --output text)"
  [ "$_create_scratch_bucket_leftover" = None ] ||
    die "scratch bucket $_create_scratch_bucket_bucket still holds objects from an earlier restore, and an S3
restore skips keys that already exist, so a run now could pass falsely. Lifecycle
expiry clears it within a few days; or pass --to-bucket with an empty
versioned bucket."
  echo "$_create_scratch_bucket_bucket"
}

# verify_bucket_versioned PROFILE REGION BUCKET: refuse an unversioned
# --to-bucket now, rather than letting the restore job fail an hour later.
verify_bucket_versioned() {
  _verify_bucket_versioned_status="$(aws_as "$1" s3api get-bucket-versioning --bucket "$3" --region "$2" \
    --query 'Status' --output text 2>/dev/null || echo None)"
  [ "$_verify_bucket_versioned_status" = "Enabled" ] ||
    die "bucket $3 does not have versioning enabled (status: $_verify_bucket_versioned_status); an S3
restore job fails outright without it. Enable it, or omit --to-bucket and
let this script create a scratch bucket instead."
}

# resolve_scratch_bucket TO_BUCKET PROFILE REGION -> a bucket name on stdout,
# with versioning verified (an explicit TO_BUCKET) or the account's stable
# scratch bucket (the default, empty TO_BUCKET).
resolve_scratch_bucket() {
  _resolve_scratch_bucket_to_bucket="$1"
  _resolve_scratch_bucket_profile="$2"
  _resolve_scratch_bucket_region="$3"
  if [ -n "$_resolve_scratch_bucket_to_bucket" ]; then
    verify_bucket_versioned "$_resolve_scratch_bucket_profile" "$_resolve_scratch_bucket_region" "$_resolve_scratch_bucket_to_bucket"
    echo "$_resolve_scratch_bucket_to_bucket"
  else
    create_scratch_bucket "$_resolve_scratch_bucket_profile" "$_resolve_scratch_bucket_region"
  fi
}

# restore_s3_to_scratch VAULT RP REGION ROLE DEST_BUCKET [PROFILE]: starts an
# S3 restore job into DEST_BUCKET and waits for it. Unlike EBS, the metadata
# needs DestinationBucketName patched in rather than availabilityZone -- S3
# has no AZ -- which is why restore_metadata (common.sh) stays generic
# instead of EBS-specific. EncryptionType is forced to SSE-S3 (rather than
# left at the API's own default of "original") because a recovery point
# copied cross-region cannot restore under its original encryption at all
# ("Can not use original encryption on recovery point that was copied from
# another region"); this is safe unconditionally, not just cross-account,
# since the media bucket's own encryption is already SSE-S3
# (modules/storage/main.tf), so the override is a no-op on the
# same-account path. RestoreACLs is forced off for the same reason: the
# media bucket is BucketOwnerEnforced, so it has no object ACLs to restore,
# but the scratch bucket (create_scratch_bucket) is ACLs-disabled by
# default too -- the API rejects RestoreACLs=true outright against a bucket
# whose BucketOwnershipControls don't allow object ACLs.
restore_s3_to_scratch() {
  _restore_s3_to_scratch_vault="$1"
  _restore_s3_to_scratch_rp="$2"
  _restore_s3_to_scratch_region="$3"
  _restore_s3_to_scratch_role="$4"
  _restore_s3_to_scratch_bucket="$5"
  _restore_s3_to_scratch_profile="${6:-}"

  _restore_s3_to_scratch_meta="$(restore_metadata "$_restore_s3_to_scratch_vault" "$_restore_s3_to_scratch_rp" "$_restore_s3_to_scratch_region" "" "$_restore_s3_to_scratch_profile" |
    jq -c --arg b "$_restore_s3_to_scratch_bucket" \
      '. + {DestinationBucketName: $b, EncryptionType: "SSE-S3", RestoreACLs: "false"}')"
  _restore_s3_to_scratch_job="$(aws_as "$_restore_s3_to_scratch_profile" backup start-restore-job --region "$_restore_s3_to_scratch_region" \
    --recovery-point-arn "$_restore_s3_to_scratch_rp" --iam-role-arn "$_restore_s3_to_scratch_role" \
    --resource-type S3 --metadata "$_restore_s3_to_scratch_meta" --query 'RestoreJobId' --output text)"
  log "Restore job started: $_restore_s3_to_scratch_job"
  poll_job "S3 restore" "$RESTORE_TICKS" "$_restore_s3_to_scratch_job" restore "$_restore_s3_to_scratch_region" "$_restore_s3_to_scratch_profile"
}

# s3_object_stats PROFILE REGION BUCKET -> "COUNT\tBYTES" on stdout.
# Pagination is automatic (the CLI merges pages before applying --query);
# `Contents[] || \`[]\`` covers an empty bucket, whose response has no
# Contents key at all -- length()/sum() would otherwise error on null.
s3_object_stats() {
  # shellcheck disable=SC2016 # single-quoted on purpose: the backticks are
  # JMESPath literal syntax, not shell command substitution.
  aws_as "$1" s3api list-objects-v2 --bucket "$3" --region "$2" \
    --query '[length(Contents[] || `[]`), sum((Contents[] || `[]`)[].Size)]' \
    --output text
}

# restore_landed_rp RP: dispatches a recovery point that is already in the
# LOCAL vault ($VAULT, read with the workload account's own credentials) to
# the right restore path by ResourceType. Shared by `local` (restores
# directly) and `copy-back` (restores what it just pulled in) -- both end
# the same way once the recovery point sits in the local vault. Callers set
# ROLE and VAULT first.
restore_landed_rp() {
  _restore_landed_rp_vol="" _restore_landed_rp_bucket=""
  _restore_landed_rp_rp="$1"
  _restore_landed_rp_rtype="$(rp_resource_type "$VAULT" "$_restore_landed_rp_rp" "$REGION")"
  case "$_restore_landed_rp_rtype" in
  EBS)
    _restore_landed_rp_vol="$(restore_ebs_into_workload "$_restore_landed_rp_rp")"
    log "Next: scripts/azmove.sh adopt $_restore_landed_rp_vol <az>  (the AZ is printed above)"
    ;;
  S3)
    _restore_landed_rp_bucket="$(resolve_scratch_bucket "" "" "$REGION")"
    log "S3 restores skip existing keys -- restoring into the LIVE media"
    log "bucket would silently do nothing for objects already there. This"
    log "restores into a scratch bucket instead: $_restore_landed_rp_bucket"
    restore_s3_to_scratch "$VAULT" "$_restore_landed_rp_rp" "$REGION" "$ROLE" "$_restore_landed_rp_bucket"
    log "Restored into: $_restore_landed_rp_bucket"
    ;;
  *) die "recovery point $_restore_landed_rp_rp has unexpected ResourceType '$_restore_landed_rp_rtype' (expected EBS or S3)" ;;
  esac
}

# --- list -----------------------------------------------------------------

cmd_list() {
  _cmd_list_mode=""
  [ "$#" -eq 0 ] || die "usage: $0 list"
  _cmd_list_rp_query='reverse(sort_by(RecoveryPoints, &CreationDate))[:10].[CreationDate,ResourceType,Status,RecoveryPointArn]'

  _cmd_list_vault="$(resolve_vault)"

  log "=== Local vault: $_cmd_list_vault ($REGION, workload account) ==="
  aws backup list-recovery-points-by-backup-vault --region "$REGION" \
    --backup-vault-name "$_cmd_list_vault" --query "$_cmd_list_rp_query" --output table

  _cmd_list_mode="$(tf_output backup_mode)"
  _cmd_list_dest="$(tf_output_opt backup_copy_vault_arn)"
  if [ -z "$_cmd_list_dest" ]; then
    log "No off-site copy destination (backup.mode is 'local')."
    return 0
  fi
  _cmd_list_dest_vault="$(printf '%s' "$_cmd_list_dest" | cut -d: -f7)"
  _cmd_list_dest_region="$(printf '%s' "$_cmd_list_dest" | cut -d: -f4)"

  if [ "$_cmd_list_mode" = cross_region ]; then
    # Same account, different region -- no second profile needed.
    log "=== Destination vault: $_cmd_list_dest_vault ($_cmd_list_dest_region, same account) ==="
    aws backup list-recovery-points-by-backup-vault --region "$_cmd_list_dest_region" \
      --backup-vault-name "$_cmd_list_dest_vault" --query "$_cmd_list_rp_query" --output table
  elif [ -n "$BACKUP_PROFILE" ]; then
    log "=== Destination vault: $_cmd_list_dest_vault ($_cmd_list_dest_region, backup account) ==="
    aws_as "$BACKUP_PROFILE" backup list-recovery-points-by-backup-vault --region "$_cmd_list_dest_region" \
      --backup-vault-name "$_cmd_list_dest_vault" --query "$_cmd_list_rp_query" --output table
  else
    log "=== Destination vault: $_cmd_list_dest_vault ($_cmd_list_dest_region, backup account) ==="
    log "Set BACKUP_PROFILE to list it -- needs the backup account's own credentials"
    log "(the isolation this design exists for is working as intended)."
  fi
}

# --- local ------------------------------------------------------------------

cmd_local() {
  [ "$#" -eq 1 ] || die "usage: $0 local <recovery-point-arn>"

  ROLE="arn:aws:iam::$(resolve_account):role/${BACKUP_ROLE_NAME}"
  readonly ROLE
  VAULT="$(resolve_vault)"
  readonly VAULT

  restore_landed_rp "$1"
}

# --- offsite ------------------------------------------------------------------

cmd_offsite() {
  _cmd_offsite_az="" _cmd_offsite_meta="" _cmd_offsite_job="" _cmd_offsite_vol="" _cmd_offsite_bucket=""
  _cmd_offsite_to_bucket=""
  [ "$#" -ge 1 ] || die "usage: $0 offsite <recovery-point-arn> [--to-bucket <name>]"
  _cmd_offsite_rp="$1"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --to-bucket)
      [ "$#" -ge 2 ] || die "usage: $0 offsite <recovery-point-arn> [--to-bucket <name>]"
      _cmd_offsite_to_bucket="$2"
      shift 2
      ;;
    *) die "usage: $0 offsite <recovery-point-arn> [--to-bucket <name>]" ;;
    esac
  done

  _cmd_offsite_backup_account="$(resolve_backup_account)"
  _cmd_offsite_role="arn:aws:iam::${_cmd_offsite_backup_account}:role/${RESTORE_ROLE_NAME}"
  _cmd_offsite_vault_dest="$(dest_vault_name)"

  _cmd_offsite_rtype="$(rp_resource_type "$_cmd_offsite_vault_dest" "$_cmd_offsite_rp" "$BACKUP_REGION" "$BACKUP_PROFILE")"
  case "$_cmd_offsite_rtype" in
  EBS)
    _cmd_offsite_az="$(aws_as "$BACKUP_PROFILE" ec2 describe-availability-zones --region "$BACKUP_REGION" \
      --query 'AvailabilityZones[0].ZoneName' --output text)"
    log "Restoring $_cmd_offsite_rp to a scratch volume in $_cmd_offsite_az (any AZ is fine -- the backup"
    log "account has no subnet of its own to match)."

    _cmd_offsite_meta="$(restore_metadata "$_cmd_offsite_vault_dest" "$_cmd_offsite_rp" "$BACKUP_REGION" "$_cmd_offsite_az" "$BACKUP_PROFILE")"
    _cmd_offsite_job="$(aws_as "$BACKUP_PROFILE" backup start-restore-job --region "$BACKUP_REGION" \
      --recovery-point-arn "$_cmd_offsite_rp" --iam-role-arn "$_cmd_offsite_role" \
      --resource-type EBS --metadata "$_cmd_offsite_meta" --query 'RestoreJobId' --output text)"
    log "Restore job started: $_cmd_offsite_job"
    poll_job "Offsite restore" "$RESTORE_TICKS" "$_cmd_offsite_job" restore "$BACKUP_REGION" "$BACKUP_PROFILE"

    _cmd_offsite_vol="$(aws_as "$BACKUP_PROFILE" backup describe-restore-job --region "$BACKUP_REGION" \
      --restore-job-id "$_cmd_offsite_job" --query 'CreatedResourceArn' --output text | awk -F/ '{print $NF}')"
    tag_restored_volume "$BACKUP_REGION" "$_cmd_offsite_vol" gramps-data-restored "$BACKUP_PROFILE"
    log "Restored volume: $_cmd_offsite_vol ($BACKUP_REGION, $_cmd_offsite_az)"
    log "Scratch only -- never attach it anywhere you intend to keep running."
    log "Delete it once you're done:"
    log "  AWS_PROFILE=$BACKUP_PROFILE aws ec2 delete-volume --region $BACKUP_REGION --volume-id $_cmd_offsite_vol"
    ;;
  S3)
    _cmd_offsite_bucket="$(resolve_scratch_bucket "$_cmd_offsite_to_bucket" "$BACKUP_PROFILE" "$BACKUP_REGION")"
    restore_s3_to_scratch "$_cmd_offsite_vault_dest" "$_cmd_offsite_rp" "$BACKUP_REGION" "$_cmd_offsite_role" "$_cmd_offsite_bucket" "$BACKUP_PROFILE"
    log "Restored into: $_cmd_offsite_bucket ($BACKUP_REGION, backup account)"
    log "Scratch only -- the bucket is stable and empties itself by lifecycle"
    log "expiry within a few days; the next restore into it is refused until then."
    ;;
  *) die "recovery point $_cmd_offsite_rp has unexpected ResourceType '$_cmd_offsite_rtype' (expected EBS or S3)" ;;
  esac
}

# --- copy-back -----------------------------------------------------------------

cmd_copy_back() {
  _cmd_copy_back_role=""
  [ "$#" -eq 1 ] || die "usage: $0 copy-back <recovery-point-arn>"
  _cmd_copy_back_rp="$1"

  _cmd_copy_back_account="$(resolve_account)"
  _cmd_copy_back_backup_account="$(resolve_backup_account)" # also validates BACKUP_PROFILE up front
  ROLE="arn:aws:iam::${_cmd_copy_back_account}:role/${BACKUP_ROLE_NAME}"
  readonly ROLE
  VAULT="$(resolve_vault)"
  readonly VAULT

  _cmd_copy_back_dest_vault="$(dest_vault_name)"
  [ -n "$_cmd_copy_back_dest_vault" ] ||
    die "the stack has no copy destination (backup.mode is not cross_region or cross_account); nothing to copy back from"
  _cmd_copy_back_role="arn:aws:iam::${_cmd_copy_back_backup_account}:role/${RESTORE_ROLE_NAME}"

  _cmd_copy_back_lifecycle="$(resolve_plan_retention "$REGION")"
  _cmd_copy_back_retention="$(printf '%s' "$_cmd_copy_back_lifecycle" | cut -f1)"

  log "Copying $_cmd_copy_back_rp back from $_cmd_copy_back_dest_vault ($BACKUP_REGION) to $VAULT ($REGION)..."
  log "This is roughly 60x slower than the outbound direction: budget 4-6 HOURS,"
  log "sitting in CREATED with no status message the whole time. That is"
  log "documented AWS Backup behavior, not a hang -- do not conclude anything"
  log "from a short poll, and do not delete $VAULT while this is queued."
  confirm "Start the copy back?"

  _cmd_copy_back_job="$(aws_as "$BACKUP_PROFILE" backup start-copy-job --region "$BACKUP_REGION" \
    --source-backup-vault-name "$_cmd_copy_back_dest_vault" \
    --destination-backup-vault-arn "arn:aws:backup:${REGION}:${_cmd_copy_back_account}:backup-vault:${VAULT}" \
    --iam-role-arn "$_cmd_copy_back_role" --recovery-point-arn "$_cmd_copy_back_rp" \
    --lifecycle "DeleteAfterDays=$_cmd_copy_back_retention" --query 'CopyJobId' --output text)"
  log "Copy job started: $_cmd_copy_back_job"
  poll_job "Copy back" "$COPY_BACK_TICKS" "$_cmd_copy_back_job" copy "$BACKUP_REGION" "$BACKUP_PROFILE"

  _cmd_copy_back_dest_rp="$(aws_as "$BACKUP_PROFILE" backup describe-copy-job --region "$BACKUP_REGION" \
    --copy-job-id "$_cmd_copy_back_job" --query 'CopyJob.DestinationRecoveryPointArn' --output text)"
  log "Landed in $VAULT as $_cmd_copy_back_dest_rp -- restoring it into the workload account..."

  restore_landed_rp "$_cmd_copy_back_dest_rp"
}

# --- drill -------------------------------------------------------------------
#
# Proves the cross-account pipeline end to end, for BOTH resource types, and
# gates locking the destination vault (docs/cross-account-backup.md). Run
# `drill-cleanup` BEFORE locking: once the vault is locked and the OU's SCP
# denies DeleteRecoveryPoint, the drill's own recovery points cannot be
# removed for the full retention window.

# PRIMARY is the EBS half, S3 the other.
DRILL_ACCOUNT=""
DRILL_BACKUP_ACCOUNT=""
DRILL_VAULT=""
DRILL_DEST_VAULT=""
DRILL_PRIMARY_JOB=""
DRILL_PRIMARY_RP=""
DRILL_S3_JOB=""
DRILL_S3_RP=""
DRILL_PRIMARY_COPY_JOB=""
DRILL_S3_COPY_JOB=""
DRILL_DEST_PRIMARY_RP=""
DRILL_DEST_S3_RP=""
DRILL_OFFSITE_PRIMARY=""
DRILL_SCRATCH_BUCKET=""

drill_preflight() {
  require_backup_mode cross_account

  DRILL_ACCOUNT="$(resolve_account)"
  DRILL_BACKUP_ACCOUNT="$(resolve_backup_account)"
  DRILL_VAULT="$(resolve_vault)"
  DRILL_DEST_VAULT="$(dest_vault_name)"

  _drill_preflight_locked="$(aws_as "$BACKUP_PROFILE" backup describe-backup-vault --region "$BACKUP_REGION" \
    --backup-vault-name "$DRILL_DEST_VAULT" --query Locked --output text 2>/dev/null || echo false)"
  [ "$_drill_preflight_locked" != "True" ] ||
    die "$DRILL_DEST_VAULT is already locked. The drill creates recovery points
it must delete afterward; a locked vault won't allow that. Run the drill
BEFORE locking (docs/cross-account-backup.md)."

  log "Preflight OK: workload=$DRILL_ACCOUNT ($REGION), backup=$DRILL_BACKUP_ACCOUNT ($BACKUP_REGION)"
  log "Vault: $DRILL_DEST_VAULT (unlocked)"
}

drill_seed() {
  _drill_seed_role="arn:aws:iam::${DRILL_ACCOUNT}:role/${BACKUP_ROLE_NAME}"
  _drill_seed_dest="$(tf_output backup_copy_vault_arn)"
  _drill_seed_primary_label="EBS"
  _drill_seed_primary_arn="$(tf_output ebs_volume_arn)"
  _drill_seed_s3_arn="$(tf_output media_bucket_arn)"

  # DRILL_RETENTION_DAYS, not the live plan's production retention: these
  # recovery points are throwaway, and a short lifecycle is the backstop when
  # drill-cleanup can't remove them (see the constant's own comment above).
  log "Seeding recovery points for the drill (crash-consistent, no downtime)..."
  _drill_seed_tags="{\"Project\":\"gramps-web\",\"Name\":\"$DRILL_TAG\"}"

  # Both jobs start before either is waited on -- same reasoning as
  # backup.sh run: the S3 half is the long pole.
  DRILL_PRIMARY_JOB="$(aws backup start-backup-job --region "$REGION" \
    --backup-vault-name "$DRILL_VAULT" --resource-arn "$_drill_seed_primary_arn" --iam-role-arn "$_drill_seed_role" \
    --lifecycle "DeleteAfterDays=$DRILL_RETENTION_DAYS" --recovery-point-tags "$_drill_seed_tags" \
    --query 'BackupJobId' --output text)"
  DRILL_S3_JOB="$(aws backup start-backup-job --region "$REGION" \
    --backup-vault-name "$DRILL_VAULT" --resource-arn "$_drill_seed_s3_arn" --iam-role-arn "$_drill_seed_role" \
    --lifecycle "DeleteAfterDays=$DRILL_RETENTION_DAYS" --recovery-point-tags "$_drill_seed_tags" \
    --query 'BackupJobId' --output text)"
  log "Backup jobs started: $_drill_seed_primary_label=$DRILL_PRIMARY_JOB S3=$DRILL_S3_JOB"
  log "The S3 job sits at 0% for most of 20-30 min -- not a hang (backup.sh run"
  log "documents the same AWS Backup behavior)."

  poll_job "Seed $_drill_seed_primary_label backup" "$BACKUP_TICKS" "$DRILL_PRIMARY_JOB" backup "$REGION"
  poll_job "Seed S3 backup" "$BACKUP_TICKS" "$DRILL_S3_JOB" backup "$REGION"

  DRILL_PRIMARY_RP="$(aws backup describe-backup-job --region "$REGION" \
    --backup-job-id "$DRILL_PRIMARY_JOB" --query RecoveryPointArn --output text)"
  DRILL_S3_RP="$(aws backup describe-backup-job --region "$REGION" \
    --backup-job-id "$DRILL_S3_JOB" --query RecoveryPointArn --output text)"
  log "Local recovery points: $_drill_seed_primary_label=$DRILL_PRIMARY_RP S3=$DRILL_S3_RP"

  DRILL_PRIMARY_COPY_JOB="$(aws backup start-copy-job --region "$REGION" \
    --source-backup-vault-name "$DRILL_VAULT" --destination-backup-vault-arn "$_drill_seed_dest" \
    --iam-role-arn "$_drill_seed_role" --recovery-point-arn "$DRILL_PRIMARY_RP" \
    --lifecycle "DeleteAfterDays=$DRILL_RETENTION_DAYS" --query 'CopyJobId' --output text)"
  DRILL_S3_COPY_JOB="$(aws backup start-copy-job --region "$REGION" \
    --source-backup-vault-name "$DRILL_VAULT" --destination-backup-vault-arn "$_drill_seed_dest" \
    --iam-role-arn "$_drill_seed_role" --recovery-point-arn "$DRILL_S3_RP" \
    --lifecycle "DeleteAfterDays=$DRILL_RETENTION_DAYS" --query 'CopyJobId' --output text)"
  poll_job "Outbound $_drill_seed_primary_label copy" "$COPY_TICKS" "$DRILL_PRIMARY_COPY_JOB" copy "$REGION"
  poll_job "Outbound S3 copy" "$COPY_TICKS" "$DRILL_S3_COPY_JOB" copy "$REGION"

  DRILL_DEST_PRIMARY_RP="$(aws backup describe-copy-job --region "$REGION" \
    --copy-job-id "$DRILL_PRIMARY_COPY_JOB" --query 'CopyJob.DestinationRecoveryPointArn' --output text)"
  DRILL_DEST_S3_RP="$(aws backup describe-copy-job --region "$REGION" \
    --copy-job-id "$DRILL_S3_COPY_JOB" --query 'CopyJob.DestinationRecoveryPointArn' --output text)"
  log "PASS: outbound KMS grants and the copy pipeline work, for both resource types."
  log "  $_drill_seed_primary_label landed as $DRILL_DEST_PRIMARY_RP"
  log "  S3  landed as $DRILL_DEST_S3_RP"
}

drill_confirm_landing() {
  aws_as "$BACKUP_PROFILE" backup describe-recovery-point --region "$BACKUP_REGION" \
    --backup-vault-name "$DRILL_DEST_VAULT" --recovery-point-arn "$DRILL_DEST_PRIMARY_RP" \
    --query 'Status' --output text >/dev/null ||
    die "$DRILL_DEST_PRIMARY_RP is not visible in $DRILL_DEST_VAULT from the backup
account's own credentials -- landing did not confirm."
  aws_as "$BACKUP_PROFILE" backup describe-recovery-point --region "$BACKUP_REGION" \
    --backup-vault-name "$DRILL_DEST_VAULT" --recovery-point-arn "$DRILL_DEST_S3_RP" \
    --query 'Status' --output text >/dev/null ||
    die "$DRILL_DEST_S3_RP is not visible in $DRILL_DEST_VAULT from the backup
account's own credentials -- landing did not confirm."
  log "PASS: both recovery points confirmed in $DRILL_DEST_VAULT from the backup account's own credentials"
}

drill_restore_offsite() {
  _drill_restore_offsite_status=""

  _drill_restore_offsite_role="arn:aws:iam::${DRILL_BACKUP_ACCOUNT}:role/${RESTORE_ROLE_NAME}"

  _drill_restore_offsite_az="$(aws_as "$BACKUP_PROFILE" ec2 describe-availability-zones --region "$BACKUP_REGION" \
    --query 'AvailabilityZones[0].ZoneName' --output text)"

  _drill_restore_offsite_meta="$(restore_metadata "$DRILL_DEST_VAULT" "$DRILL_DEST_PRIMARY_RP" "$BACKUP_REGION" "$_drill_restore_offsite_az" "$BACKUP_PROFILE")"
  _drill_restore_offsite_job="$(aws_as "$BACKUP_PROFILE" backup start-restore-job --region "$BACKUP_REGION" \
    --recovery-point-arn "$DRILL_DEST_PRIMARY_RP" --iam-role-arn "$_drill_restore_offsite_role" \
    --resource-type EBS --metadata "$_drill_restore_offsite_meta" --query 'RestoreJobId' --output text)"
  poll_job "Offsite EBS restore" "$RESTORE_TICKS" "$_drill_restore_offsite_job" restore "$BACKUP_REGION" "$BACKUP_PROFILE"

  DRILL_OFFSITE_PRIMARY="$(aws_as "$BACKUP_PROFILE" backup describe-restore-job --region "$BACKUP_REGION" \
    --restore-job-id "$_drill_restore_offsite_job" --query 'CreatedResourceArn' --output text | awk -F/ '{print $NF}')"
  _drill_restore_offsite_size="$(aws_as "$BACKUP_PROFILE" ec2 describe-volumes --region "$BACKUP_REGION" \
    --volume-ids "$DRILL_OFFSITE_PRIMARY" --query 'Volumes[0].Size' --output text)"
  case "$_drill_restore_offsite_size" in
  [1-9]*) ;;
  *) die "restored volume $DRILL_OFFSITE_PRIMARY reports size '$_drill_restore_offsite_size', not a positive
number of GiB -- the recovery point may be empty." ;;
  esac
  log "PASS (EBS): restored to $DRILL_OFFSITE_PRIMARY ($BACKUP_REGION, $_drill_restore_offsite_az, ${_drill_restore_offsite_size}GiB) --"
  log "the destination CMK and the restore role both work. Size only -- see the"
  log "header for why full content verification is a manual exercise here."

  DRILL_SCRATCH_BUCKET="$(create_scratch_bucket "$BACKUP_PROFILE" "$BACKUP_REGION")"
  restore_s3_to_scratch "$DRILL_DEST_VAULT" "$DRILL_DEST_S3_RP" "$BACKUP_REGION" "$_drill_restore_offsite_role" \
    "$DRILL_SCRATCH_BUCKET" "$BACKUP_PROFILE"

  # An S3 recovery point reports BackupSizeInBytes: 0 -- count what actually
  # landed instead of trusting the recovery point's own metadata.
  _drill_restore_offsite_stats="$(s3_object_stats "$BACKUP_PROFILE" "$BACKUP_REGION" "$DRILL_SCRATCH_BUCKET")"
  _drill_restore_offsite_r_count="$(printf '%s' "$_drill_restore_offsite_stats" | cut -f1)"
  _drill_restore_offsite_r_bytes="$(printf '%s' "$_drill_restore_offsite_stats" | cut -f2)"

  _drill_restore_offsite_media_bucket="$(tf_output media_bucket_name)"
  _drill_restore_offsite_live_stats="$(s3_object_stats "" "$REGION" "$_drill_restore_offsite_media_bucket")"
  _drill_restore_offsite_l_count="$(printf '%s' "$_drill_restore_offsite_live_stats" | cut -f1)"
  _drill_restore_offsite_l_bytes="$(printf '%s' "$_drill_restore_offsite_live_stats" | cut -f2)"

  [ "$_drill_restore_offsite_r_count" = "$_drill_restore_offsite_l_count" ] && [ "$_drill_restore_offsite_r_bytes" = "$_drill_restore_offsite_l_bytes" ] ||
    die "FAIL (S3): restored $DRILL_SCRATCH_BUCKET has $_drill_restore_offsite_r_count objects /
$_drill_restore_offsite_r_bytes bytes, but the live bucket $_drill_restore_offsite_media_bucket has $_drill_restore_offsite_l_count objects /
$_drill_restore_offsite_l_bytes bytes. Content did not land intact."
  log "PASS (S3): restored $_drill_restore_offsite_r_count objects / $_drill_restore_offsite_r_bytes bytes into"
  log "$DRILL_SCRATCH_BUCKET, matching the live bucket exactly -- real content"
  log "proof, no compute needed."
}

# drill_negative_test RP LABEL: the workload account, using its OWN default
# credentials (not BACKUP_PROFILE), attempts to delete RP from the
# DESTINATION vault it does not own. AccessDeniedException is the pass -- the
# vault policy grants it CopyIntoBackupVault and nothing else
# (aws_backup_vault_policy.replica in keel backup-vault-account).
# Run once per resource type: the isolation guarantee has to hold for both.
drill_negative_test() {
  _drill_negative_test_rp="$1"
  _drill_negative_test_label="$2"
  set +e
  _drill_negative_test_out="$(aws backup delete-recovery-point --region "$BACKUP_REGION" \
    --backup-vault-name "$DRILL_DEST_VAULT" --recovery-point-arn "$_drill_negative_test_rp" 2>&1)"
  _drill_negative_test_status=$?
  set -e
  [ "$_drill_negative_test_status" -ne 0 ] ||
    die "FAIL ($_drill_negative_test_label): the workload account deleted $_drill_negative_test_rp from $DRILL_DEST_VAULT --
the isolation this design exists for is not real. Check
aws_backup_vault_policy.replica in keel backup-vault-account."
  case "$_drill_negative_test_out" in
  *AccessDenied*)
    log "PASS ($_drill_negative_test_label): the workload account cannot delete from $DRILL_DEST_VAULT (AccessDeniedException, as designed)"
    ;;
  *)
    die "drill inconclusive ($_drill_negative_test_label): delete-recovery-point failed, but not with
AccessDenied: $_drill_negative_test_out"
    ;;
  esac
}

drill_write_manifest() {
  _drill_write_manifest_manifest="restore-drill-$(date -u +%Y%m%d%H%M%S).json"
  jq -n \
    --arg local_primary_rp "$DRILL_PRIMARY_RP" --arg dest_primary_rp "$DRILL_DEST_PRIMARY_RP" \
    --arg local_s3_rp "$DRILL_S3_RP" --arg dest_s3_rp "$DRILL_DEST_S3_RP" \
    --arg dest_vault "$DRILL_DEST_VAULT" --arg backup_region "$BACKUP_REGION" \
    --arg offsite_primary "$DRILL_OFFSITE_PRIMARY" \
    '{
      local_primary_recovery_point: $local_primary_rp,
      destination_primary_recovery_point: $dest_primary_rp,
      local_s3_recovery_point: $local_s3_rp,
      destination_s3_recovery_point: $dest_s3_rp,
      destination_vault: $dest_vault,
      backup_region: $backup_region,
      offsite_primary_resource: $offsite_primary,
      local_primary_recovery_point_deleted: false,
      destination_primary_recovery_point_deleted: false,
      local_s3_recovery_point_deleted: false,
      destination_s3_recovery_point_deleted: false,
      offsite_primary_resource_deleted: false,
      cleaned: false
    }' \
    >"$_drill_write_manifest_manifest"
  echo "$_drill_write_manifest_manifest"
}

cmd_drill() {
  [ "$#" -eq 0 ] || die "usage: $0 drill"

  drill_preflight
  drill_seed
  drill_confirm_landing
  drill_restore_offsite
  drill_negative_test "$DRILL_DEST_PRIMARY_RP" EBS
  drill_negative_test "$DRILL_DEST_S3_RP" S3

  _cmd_drill_manifest="$(drill_write_manifest)"
  log ""
  log "=== DRILL PASSED ==="
  log "Artifacts recorded in $_cmd_drill_manifest."
  log "Run '$0 drill-cleanup' BEFORE locking the vault -- a locked vault"
  log "cannot delete what this drill just created. If the protective SCPs"
  log "from docs/cross-account-backup.md are already attached, cleanup may"
  log "not be able to remove the destination recovery points either -- they"
  log "are on a $DRILL_RETENTION_DAYS-day lifecycle and expire on their own regardless."
  log "Once cleanup is done, lock it (docs/cross-account-backup.md):"
  log "  vault_lock = { mode = \"governance\", min_retention_days = 7, max_retention_days = 365 }"
  log "  then apply the backup account's root with AWS_PROFILE=$BACKUP_PROFILE"
}

# CLEANUP_ERR: set by the delete_* helpers on
# failure, read by explain_cleanup_failure. A plain global
# since it crosses from a helper's return status back to its caller's log
# message.
CLEANUP_ERR=""

# delete_offsite_volume REGION VOL: 0 if deleted or already gone, 1
# otherwise (CLEANUP_ERR set).
delete_offsite_volume() {
  _delete_offsite_volume_out="$(aws_as "$BACKUP_PROFILE" ec2 delete-volume --region "$1" --volume-id "$2" 2>&1)"
  _delete_offsite_volume_status=$?
  [ "$_delete_offsite_volume_status" -eq 0 ] && return 0
  case "$_delete_offsite_volume_out" in
  *InvalidVolume.NotFound*) return 0 ;; # already gone -- idempotent success
  esac
  CLEANUP_ERR="$_delete_offsite_volume_out"
  return 1
}

# delete_recovery_point PROFILE REGION VAULT RP: 0 if deleted or already
# gone, 1 otherwise (CLEANUP_ERR set). PROFILE may be empty (workload
# account, no override -- see aws_as).
delete_recovery_point() {
  _delete_recovery_point_out="$(aws_as "$1" backup delete-recovery-point --region "$2" \
    --backup-vault-name "$3" --recovery-point-arn "$4" 2>&1)"
  _delete_recovery_point_status=$?
  [ "$_delete_recovery_point_status" -eq 0 ] && return 0
  case "$_delete_recovery_point_out" in
  *ResourceNotFoundException* | *"Cannot find recovery point"*) return 0 ;;
  esac
  CLEANUP_ERR="$_delete_recovery_point_out"
  return 1
}

# explain_cleanup_failure LABEL: logs why a delete_* helper failed, reading
# CLEANUP_ERR it left behind. An SCP explicit deny gets a specific explanation
# (the trap "Protecting the backup account with SCPs" in
# docs/cross-account-backup.md sets, if attached before a drill/cleanup cycle
# has run clean); anything else is a plain WARN. A recovery point ages off on
# its own via DRILL_RETENTION_DAYS.
explain_cleanup_failure() {
  case "$CLEANUP_ERR" in
  *"explicit deny"*"service control policy"*)
    log "  $1: BLOCKED by an SCP explicit deny (the protective SCP from"
    log "    docs/cross-account-backup.md). It can't be deleted manually while"
    log "    that's attached -- but it's on a $DRILL_RETENTION_DAYS-day lifecycle and"
    log "    expires on its own via AWS Backup's service-linked role, which"
    log "    SCPs don't reach. To remove it sooner, detach or scope down that"
    log "    SCP from the management account first."
    ;;
  *)
    log "  $1: WARN -- could not delete: $CLEANUP_ERR"
    ;;
  esac
}

cmd_drill_cleanup() {
  _cmd_drill_cleanup_manifest=""
  _cmd_drill_cleanup_all_done=""
  [ "$#" -le 1 ] || die "usage: $0 drill-cleanup [manifest]"
  _cmd_drill_cleanup_manifest="${1:-}"
  if [ -z "$_cmd_drill_cleanup_manifest" ]; then
    _cmd_drill_cleanup_manifest="$(find . -maxdepth 1 -name 'restore-drill-*.json' 2>/dev/null | sort | tail -n 1)"
  fi
  [ -f "$_cmd_drill_cleanup_manifest" ] ||
    die "no drill manifest found. Pass one explicitly, or run '$0 drill' first."
  [ -n "$BACKUP_PROFILE" ] ||
    die "BACKUP_PROFILE not set; drill-cleanup needs the backup account's own credentials"

  _cmd_drill_cleanup_local_primary_rp="$(jq -r '.local_primary_recovery_point // ""' "$_cmd_drill_cleanup_manifest")"
  _cmd_drill_cleanup_dest_primary_rp="$(jq -r '.destination_primary_recovery_point // ""' "$_cmd_drill_cleanup_manifest")"
  _cmd_drill_cleanup_local_s3_rp="$(jq -r '.local_s3_recovery_point // ""' "$_cmd_drill_cleanup_manifest")"
  _cmd_drill_cleanup_dest_s3_rp="$(jq -r '.destination_s3_recovery_point // ""' "$_cmd_drill_cleanup_manifest")"
  _cmd_drill_cleanup_dest_vault="$(jq -r '.destination_vault // ""' "$_cmd_drill_cleanup_manifest")"
  _cmd_drill_cleanup_backup_region="$(jq -r '.backup_region // ""' "$_cmd_drill_cleanup_manifest")"
  _cmd_drill_cleanup_offsite_primary="$(jq -r '.offsite_primary_resource // ""' "$_cmd_drill_cleanup_manifest")"
  # Per-artifact flags: a missing flag in an older manifest just means
  # "nothing confirmed deleted yet" -- a harmless retry of whatever remains.
  _cmd_drill_cleanup_local_primary_done="$(jq -r '.local_primary_recovery_point_deleted // false' "$_cmd_drill_cleanup_manifest")"
  _cmd_drill_cleanup_dest_primary_done="$(jq -r '.destination_primary_recovery_point_deleted // false' "$_cmd_drill_cleanup_manifest")"
  _cmd_drill_cleanup_local_s3_done="$(jq -r '.local_s3_recovery_point_deleted // false' "$_cmd_drill_cleanup_manifest")"
  _cmd_drill_cleanup_dest_s3_done="$(jq -r '.destination_s3_recovery_point_deleted // false' "$_cmd_drill_cleanup_manifest")"
  _cmd_drill_cleanup_offsite_done="$(jq -r '.offsite_primary_resource_deleted // false' "$_cmd_drill_cleanup_manifest")"

  VAULT="$(tf_output_opt backup_vault_name)"

  log "Manifest: $_cmd_drill_cleanup_manifest (EBS)"
  log "  local EBS recovery point:       ${_cmd_drill_cleanup_local_primary_rp:-(none)}"
  log "  destination EBS recovery point: ${_cmd_drill_cleanup_dest_primary_rp:-(none)}"
  log "  local S3 recovery point:        ${_cmd_drill_cleanup_local_s3_rp:-(none)}"
  log "  destination S3 recovery point:  ${_cmd_drill_cleanup_dest_s3_rp:-(none)}"
  log "  offsite scratch EBS resource:    ${_cmd_drill_cleanup_offsite_primary:-(none)}"
  confirm "Delete what's left of these drill artifacts?"

  if [ -z "$_cmd_drill_cleanup_offsite_primary" ] || [ "$_cmd_drill_cleanup_offsite_primary" = null ]; then
    _cmd_drill_cleanup_offsite_done=true
  elif [ "$_cmd_drill_cleanup_offsite_done" != true ]; then
    if delete_offsite_volume "$_cmd_drill_cleanup_backup_region" "$_cmd_drill_cleanup_offsite_primary"; then
      _cmd_drill_cleanup_offsite_done=true
      log "  offsite volume $_cmd_drill_cleanup_offsite_primary: deleted (or already gone)"
    else
      explain_cleanup_failure "offsite volume $_cmd_drill_cleanup_offsite_primary"
    fi
  fi

  if [ -z "$_cmd_drill_cleanup_dest_primary_rp" ] || [ "$_cmd_drill_cleanup_dest_primary_rp" = null ]; then
    _cmd_drill_cleanup_dest_primary_done=true
  elif [ "$_cmd_drill_cleanup_dest_primary_done" != true ]; then
    if delete_recovery_point "$BACKUP_PROFILE" "$_cmd_drill_cleanup_backup_region" "$_cmd_drill_cleanup_dest_vault" "$_cmd_drill_cleanup_dest_primary_rp"; then
      _cmd_drill_cleanup_dest_primary_done=true
      log "  destination EBS recovery point $_cmd_drill_cleanup_dest_primary_rp: deleted (or already gone)"
    else
      explain_cleanup_failure "destination EBS recovery point $_cmd_drill_cleanup_dest_primary_rp"
    fi
  fi

  if [ -z "$_cmd_drill_cleanup_dest_s3_rp" ] || [ "$_cmd_drill_cleanup_dest_s3_rp" = null ]; then
    _cmd_drill_cleanup_dest_s3_done=true
  elif [ "$_cmd_drill_cleanup_dest_s3_done" != true ]; then
    if delete_recovery_point "$BACKUP_PROFILE" "$_cmd_drill_cleanup_backup_region" "$_cmd_drill_cleanup_dest_vault" "$_cmd_drill_cleanup_dest_s3_rp"; then
      _cmd_drill_cleanup_dest_s3_done=true
      log "  destination S3 recovery point $_cmd_drill_cleanup_dest_s3_rp: deleted (or already gone)"
    else
      explain_cleanup_failure "destination S3 recovery point $_cmd_drill_cleanup_dest_s3_rp"
    fi
  fi

  if [ -z "$_cmd_drill_cleanup_local_primary_rp" ] || [ "$_cmd_drill_cleanup_local_primary_rp" = null ] || [ -z "$VAULT" ]; then
    _cmd_drill_cleanup_local_primary_done=true
  elif [ "$_cmd_drill_cleanup_local_primary_done" != true ]; then
    if delete_recovery_point "" "$REGION" "$VAULT" "$_cmd_drill_cleanup_local_primary_rp"; then
      _cmd_drill_cleanup_local_primary_done=true
      log "  local EBS recovery point $_cmd_drill_cleanup_local_primary_rp: deleted (or already gone)"
    else
      explain_cleanup_failure "local EBS recovery point $_cmd_drill_cleanup_local_primary_rp"
    fi
  fi

  if [ -z "$_cmd_drill_cleanup_local_s3_rp" ] || [ "$_cmd_drill_cleanup_local_s3_rp" = null ] || [ -z "$VAULT" ]; then
    _cmd_drill_cleanup_local_s3_done=true
  elif [ "$_cmd_drill_cleanup_local_s3_done" != true ]; then
    if delete_recovery_point "" "$REGION" "$VAULT" "$_cmd_drill_cleanup_local_s3_rp"; then
      _cmd_drill_cleanup_local_s3_done=true
      log "  local S3 recovery point $_cmd_drill_cleanup_local_s3_rp: deleted (or already gone)"
    else
      explain_cleanup_failure "local S3 recovery point $_cmd_drill_cleanup_local_s3_rp"
    fi
  fi

  if [ "$_cmd_drill_cleanup_local_primary_done" = true ] && [ "$_cmd_drill_cleanup_dest_primary_done" = true ] &&
    [ "$_cmd_drill_cleanup_local_s3_done" = true ] && [ "$_cmd_drill_cleanup_dest_s3_done" = true ] &&
    [ "$_cmd_drill_cleanup_offsite_done" = true ]; then
    _cmd_drill_cleanup_all_done=true
  else
    _cmd_drill_cleanup_all_done=false
  fi

  jq --argjson local_primary_done "$_cmd_drill_cleanup_local_primary_done" --argjson dest_primary_done "$_cmd_drill_cleanup_dest_primary_done" \
    --argjson local_s3_done "$_cmd_drill_cleanup_local_s3_done" --argjson dest_s3_done "$_cmd_drill_cleanup_dest_s3_done" \
    --argjson offsite_done "$_cmd_drill_cleanup_offsite_done" \
    --argjson cleaned "$_cmd_drill_cleanup_all_done" \
    '.local_primary_recovery_point_deleted = $local_primary_done
     | .destination_primary_recovery_point_deleted = $_cmd_drill_cleanup_dest_primary_done
     | .local_s3_recovery_point_deleted = $_cmd_drill_cleanup_local_s3_done
     | .destination_s3_recovery_point_deleted = $_cmd_drill_cleanup_dest_s3_done
     | .offsite_primary_resource_deleted = $_cmd_drill_cleanup_offsite_done
     | .cleaned = $cleaned' \
    "$_cmd_drill_cleanup_manifest" >"$_cmd_drill_cleanup_manifest.tmp" && mv "$_cmd_drill_cleanup_manifest.tmp" "$_cmd_drill_cleanup_manifest"

  if [ "$_cmd_drill_cleanup_all_done" = true ]; then
    log "Cleanup done. Verify: $0 list"
  else
    log "Cleanup incomplete -- see above for what's blocking it and why."
    log "Re-run '$0 drill-cleanup $_cmd_drill_cleanup_manifest' to retry; anything already"
    log "deleted is skipped."
  fi
}

# --- dispatch ----------------------------------------------------------------

main() {
  require aws terraform jq
  ! wants_usage "$@" || usage
  select_root "$@"
  shift "$ROOT_SHIFT"
  init_root
  BACKUP_REGION="$(tf_output backup_region)"
  readonly BACKUP_REGION
  [ "$#" -ge 1 ] || usage
  _main_cmd="$1"
  shift
  case "$_main_cmd" in
  list) cmd_list "$@" ;;
  local) cmd_local "$@" ;;
  offsite) cmd_offsite "$@" ;;
  copy-back) cmd_copy_back "$@" ;;
  drill) cmd_drill "$@" ;;
  drill-cleanup) cmd_drill_cleanup "$@" ;;
  *) die "unknown subcommand '$_main_cmd' (expected: list|local|offsite|copy-back|drill|drill-cleanup)" ;;
  esac
}

main "$@"
