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
# from tfvars + repo-constant resource names, the same way backup.sh and the
# storage module do -- never by reading the backup account's own Terraform
# state, which is exactly what that account exists to avoid.
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
# Env: ENV (default prod; selects terraform/config/stack/<env>), AWS_REGION
#      (default: primary_region from the env's tfvars), BACKUP_PROFILE
#      (required for offsite/copy-back/drill/drill-cleanup), FORCE=1 (skip
#      prompts).
set -eu

SCRIPT_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly SCRIPT_DIR
REPO_ROOT="$(dirname -- "$SCRIPT_DIR")"
readonly REPO_ROOT

readonly LOG_PREFIX="restore"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

env_paths
REGION="$(resolve_region "$TFVARS")"
readonly REGION
BACKUP_REGION="$(resolve_backup_region)"
readonly BACKUP_REGION
BACKUP_PROFILE="${BACKUP_PROFILE:-}"
readonly BACKUP_PROFILE

# Repo constants -- see backup.sh's own header for why these are constants
# rather than Terraform outputs (a name mismatch fails loudly, not silently).
readonly BACKUP_ROLE_NAME="gramps-web-backup"     # workload account
readonly RESTORE_ROLE_NAME="gramps-web-restore"   # backup account (roots/backup-account/iam.tf)
readonly BACKUP_PLAN_NAME="gramps-web-daily"
readonly DRILL_TAG="gramps-web-restore-drill"
# Drill artifacts are throwaway; a short, fixed retention means a failed
# drill-cleanup (an SCP deny -- see "Protecting the backup account with
# SCPs" in docs/cross-account-backup.md -- a transient error, or forgetting
# to run it at all) self-expires in a day instead of riding the full
# production retention window. This is also the reason the drill's preflight
# refuses to run against an already-locked vault: this deployment's real
# lock sets min_retention_days = 7 (terraform/config/backup-account), which
# would reject a 1-day copy outright -- the drill can only ever run BEFORE
# the vault is locked.
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
# against the workload tfvars' backup.account_id. The counterpart to
# common.sh's resolve_account for the second account this script talks to.
resolve_backup_account() {
  local want got
  want="$(backup_field account_id "")"
  [ -n "$want" ] ||
    die "backup.account_id is empty in $TFVARS; backup.mode must be cross_account"
  [ -n "$BACKUP_PROFILE" ] ||
    die "BACKUP_PROFILE not set; this needs the backup account's own credentials"
  got="$(aws_as "$BACKUP_PROFILE" sts get-caller-identity --query Account --output text)" ||
    die "could not read caller identity for BACKUP_PROFILE=$BACKUP_PROFILE"
  [ "$want" = "$got" ] ||
    die "wrong account: BACKUP_PROFILE=$BACKUP_PROFILE resolves to $got, but $TFVARS
declares backup.account_id = $want."
  echo "$got"
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
  local rp az meta job vol
  rp="$1"
  az="$(aws ec2 describe-volumes --region "$REGION" \
    --volume-ids "$(tf_output ebs_volume_id)" \
    --query 'Volumes[0].AvailabilityZone' --output text)"

  meta="$(restore_metadata "$VAULT" "$rp" "$REGION" "$az")"
  job="$(aws backup start-restore-job --region "$REGION" \
    --recovery-point-arn "$rp" --iam-role-arn "$ROLE" \
    --resource-type EBS --metadata "$meta" --query 'RestoreJobId' --output text)"
  log "Restore job started: $job"
  poll_job "Restore" "$RESTORE_TICKS" "$job" restore "$REGION"

  vol="$(aws backup describe-restore-job --region "$REGION" --restore-job-id "$job" \
    --query 'CreatedResourceArn' --output text | awk -F/ '{print $NF}')"
  tag_restored_volume "$REGION" "$vol" gramps-data
  log "Restored volume: $vol (tagged Project=gramps-web, in $az -- the live subnet's AZ)"
  echo "$vol"
}

# --- scratch S3 destination ---------------------------------------------------
#
# An S3 restore needs a destination bucket with versioning enabled -- the job
# fails outright otherwise -- and the backup account has none
# (roots/backup-account provisions a vault, a key, and a role, nothing else).

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
  local profile region account bucket leftover head_out head_err
  profile="$1"
  region="$2"
  account="$(aws_as "$profile" sts get-caller-identity --query 'Account' --output text)" ||
    die "could not read caller identity for the scratch bucket name."
  bucket="gramps-web-restore-${account}-${region}"

  head_err=0
  head_out="$(aws_as "$profile" s3api head-bucket --bucket "$bucket" 2>&1)" || head_err=1
  if [ "$head_err" = 1 ]; then
    case "$head_out" in
      *"(404)"* | *"Not Found"*) ;;
      *) die "could not check scratch bucket $bucket: $head_out" ;;
    esac
    log "Creating scratch bucket $bucket ($region)..."
    # us-east-1 is the one region create-bucket rejects a LocationConstraint
    # for -- it is implicit there and an explicit one is a 400.
    if [ "$region" = "us-east-1" ]; then
      aws_as "$profile" s3api create-bucket --bucket "$bucket" --region "$region" >/dev/null
    else
      aws_as "$profile" s3api create-bucket --bucket "$bucket" --region "$region" \
        --create-bucket-configuration "LocationConstraint=$region" >/dev/null
    fi
  fi
  aws_as "$profile" s3api put-bucket-versioning --bucket "$bucket" --region "$region" \
    --versioning-configuration Status=Enabled
  aws_as "$profile" s3api put-public-access-block --bucket "$bucket" --region "$region" \
    --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws_as "$profile" s3api put-bucket-lifecycle-configuration --bucket "$bucket" --region "$region" \
    --lifecycle-configuration "$SCRATCH_LIFECYCLE" ||
    die "could not set the lifecycle rule on $bucket. It is what empties the scratch bucket
between restores; check that no policy (such as the Backup OU's SCP) denies
s3:PutLifecycleConfiguration there."

  leftover="$(aws_as "$profile" s3api list-object-versions --bucket "$bucket" --region "$region" \
    --max-items 1 --query '(Versions[0].Key || DeleteMarkers[0].Key)' --output text)"
  [ "$leftover" = None ] ||
    die "scratch bucket $bucket still holds objects from an earlier restore, and an S3
restore skips keys that already exist, so a run now could pass falsely. Lifecycle
expiry clears it within a few days; or pass --to-bucket with an empty
versioned bucket."
  echo "$bucket"
}

# verify_bucket_versioned PROFILE REGION BUCKET: refuse an unversioned
# --to-bucket now, rather than letting the restore job fail an hour later.
verify_bucket_versioned() {
  local status
  status="$(aws_as "$1" s3api get-bucket-versioning --bucket "$3" --region "$2" \
    --query 'Status' --output text 2>/dev/null || echo None)"
  [ "$status" = "Enabled" ] ||
    die "bucket $3 does not have versioning enabled (status: $status); an S3
restore job fails outright without it. Enable it, or omit --to-bucket and
let this script create a scratch bucket instead."
}

# resolve_scratch_bucket TO_BUCKET PROFILE REGION -> a bucket name on stdout,
# with versioning verified (an explicit TO_BUCKET) or the account's stable
# scratch bucket (the default, empty TO_BUCKET).
resolve_scratch_bucket() {
  local to_bucket profile region
  to_bucket="$1"
  profile="$2"
  region="$3"
  if [ -n "$to_bucket" ]; then
    verify_bucket_versioned "$profile" "$region" "$to_bucket"
    echo "$to_bucket"
  else
    create_scratch_bucket "$profile" "$region"
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
  local vault rp region role bucket profile meta job
  vault="$1"
  rp="$2"
  region="$3"
  role="$4"
  bucket="$5"
  profile="${6:-}"

  meta="$(restore_metadata "$vault" "$rp" "$region" "" "$profile" |
    jq -c --arg b "$bucket" \
      '. + {DestinationBucketName: $b, EncryptionType: "SSE-S3", RestoreACLs: "false"}')"
  job="$(aws_as "$profile" backup start-restore-job --region "$region" \
    --recovery-point-arn "$rp" --iam-role-arn "$role" \
    --resource-type S3 --metadata "$meta" --query 'RestoreJobId' --output text)"
  log "Restore job started: $job"
  poll_job "S3 restore" "$RESTORE_TICKS" "$job" restore "$region" "$profile"
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
  local rp rtype vol bucket
  rp="$1"
  rtype="$(rp_resource_type "$VAULT" "$rp" "$REGION")"
  case "$rtype" in
  EBS)
    vol="$(restore_ebs_into_workload "$rp")"
    log "Next: scripts/azmove.sh adopt $vol <az>  (the AZ is printed above)"
    ;;
  S3)
    bucket="$(resolve_scratch_bucket "" "" "$REGION")"
    log "S3 restores skip existing keys -- restoring into the LIVE media"
    log "bucket would silently do nothing for objects already there. This"
    log "restores into a scratch bucket instead: $bucket"
    restore_s3_to_scratch "$VAULT" "$rp" "$REGION" "$ROLE" "$bucket"
    log "Restored into: $bucket"
    ;;
  *) die "recovery point $rp has unexpected ResourceType '$rtype' (expected EBS or S3)" ;;
  esac
}

# --- list -----------------------------------------------------------------

cmd_list() {
  local vault mode dest dest_vault dest_region rp_query
  [ "$#" -eq 0 ] || die "usage: $0 list"
  rp_query='reverse(sort_by(RecoveryPoints, &CreationDate))[:10].[CreationDate,ResourceType,Status,RecoveryPointArn]'

  vault="$(tf_output_opt backup_vault_name)"
  [ -n "$vault" ] ||
    die "no backup vault for '$ENV': backup.mode is 'disabled' in $TFVARS."

  log "=== Local vault: $vault ($REGION, workload account) ==="
  aws backup list-recovery-points-by-backup-vault --region "$REGION" \
    --backup-vault-name "$vault" --query "$rp_query" --output table

  mode="$(backup_field mode local)"
  dest="$(resolve_dest_vault_arn)"
  if [ -z "$dest" ]; then
    log "No off-site copy destination (backup.mode is 'local')."
    return 0
  fi
  dest_vault="$(printf '%s' "$dest" | cut -d: -f7)"
  dest_region="$(printf '%s' "$dest" | cut -d: -f4)"

  if [ "$mode" = cross_region ]; then
    # Same account, different region -- no second profile needed.
    log "=== Destination vault: $dest_vault ($dest_region, same account) ==="
    aws backup list-recovery-points-by-backup-vault --region "$dest_region" \
      --backup-vault-name "$dest_vault" --query "$rp_query" --output table
  elif [ -n "$BACKUP_PROFILE" ]; then
    log "=== Destination vault: $dest_vault ($dest_region, backup account) ==="
    aws_as "$BACKUP_PROFILE" backup list-recovery-points-by-backup-vault --region "$dest_region" \
      --backup-vault-name "$dest_vault" --query "$rp_query" --output table
  else
    log "=== Destination vault: $dest_vault ($dest_region, backup account) ==="
    log "Set BACKUP_PROFILE to list it -- needs the backup account's own credentials"
    log "(the isolation this design exists for is working as intended)."
  fi
}

# --- local ------------------------------------------------------------------

cmd_local() {
  [ "$#" -eq 1 ] || die "usage: $0 local <recovery-point-arn>"

  ROLE="arn:aws:iam::$(resolve_account):role/${BACKUP_ROLE_NAME}"
  readonly ROLE
  VAULT="$(tf_output_opt backup_vault_name)"
  readonly VAULT
  [ -n "$VAULT" ] || die "no backup vault for '$ENV': backup.mode is 'disabled' in $TFVARS."

  restore_landed_rp "$1"
}

# --- offsite ------------------------------------------------------------------

cmd_offsite() {
  local rp to_bucket backup_account role vault_dest rtype az meta job vol bucket
  to_bucket=""
  [ "$#" -ge 1 ] || die "usage: $0 offsite <recovery-point-arn> [--to-bucket <name>]"
  rp="$1"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --to-bucket)
      [ "$#" -ge 2 ] || die "usage: $0 offsite <recovery-point-arn> [--to-bucket <name>]"
      to_bucket="$2"
      shift 2
      ;;
    *) die "usage: $0 offsite <recovery-point-arn> [--to-bucket <name>]" ;;
    esac
  done

  backup_account="$(resolve_backup_account)"
  role="arn:aws:iam::${backup_account}:role/${RESTORE_ROLE_NAME}"
  vault_dest="$(backup_field dest_vault_name gramps-web-backup-replica)"

  rtype="$(rp_resource_type "$vault_dest" "$rp" "$BACKUP_REGION" "$BACKUP_PROFILE")"
  case "$rtype" in
  EBS)
    az="$(aws_as "$BACKUP_PROFILE" ec2 describe-availability-zones --region "$BACKUP_REGION" \
      --query 'AvailabilityZones[0].ZoneName' --output text)"
    log "Restoring $rp to a scratch volume in $az (any AZ is fine -- the backup"
    log "account has no subnet of its own to match)."

    meta="$(restore_metadata "$vault_dest" "$rp" "$BACKUP_REGION" "$az" "$BACKUP_PROFILE")"
    job="$(aws_as "$BACKUP_PROFILE" backup start-restore-job --region "$BACKUP_REGION" \
      --recovery-point-arn "$rp" --iam-role-arn "$role" \
      --resource-type EBS --metadata "$meta" --query 'RestoreJobId' --output text)"
    log "Restore job started: $job"
    poll_job "Offsite restore" "$RESTORE_TICKS" "$job" restore "$BACKUP_REGION" "$BACKUP_PROFILE"

    vol="$(aws_as "$BACKUP_PROFILE" backup describe-restore-job --region "$BACKUP_REGION" \
      --restore-job-id "$job" --query 'CreatedResourceArn' --output text | awk -F/ '{print $NF}')"
    tag_restored_volume "$BACKUP_REGION" "$vol" gramps-data-restored "$BACKUP_PROFILE"
    log "Restored volume: $vol ($BACKUP_REGION, $az)"
    log "Scratch only -- never attach it anywhere you intend to keep running."
    log "Delete it once you're done:"
    log "  AWS_PROFILE=$BACKUP_PROFILE aws ec2 delete-volume --region $BACKUP_REGION --volume-id $vol"
    ;;
  S3)
    bucket="$(resolve_scratch_bucket "$to_bucket" "$BACKUP_PROFILE" "$BACKUP_REGION")"
    restore_s3_to_scratch "$vault_dest" "$rp" "$BACKUP_REGION" "$role" "$bucket" "$BACKUP_PROFILE"
    log "Restored into: $bucket ($BACKUP_REGION, backup account)"
    log "Scratch only -- the bucket is stable and empties itself by lifecycle"
    log "expiry within a few days; the next restore into it is refused until then."
    ;;
  *) die "recovery point $rp has unexpected ResourceType '$rtype' (expected EBS or S3)" ;;
  esac
}

# --- copy-back -----------------------------------------------------------------

cmd_copy_back() {
  local rp account backup_account dest_vault role lifecycle retention job dest_rp
  [ "$#" -eq 1 ] || die "usage: $0 copy-back <recovery-point-arn>"
  rp="$1"

  account="$(resolve_account)"
  backup_account="$(resolve_backup_account)" # also validates BACKUP_PROFILE up front
  ROLE="arn:aws:iam::${account}:role/${BACKUP_ROLE_NAME}"
  readonly ROLE
  VAULT="$(tf_output_opt backup_vault_name)"
  readonly VAULT
  [ -n "$VAULT" ] || die "no backup vault for '$ENV': backup.mode is 'disabled' in $TFVARS."

  dest_vault="$(printf '%s' "$(resolve_dest_vault_arn)" | cut -d: -f7)"
  [ -n "$dest_vault" ] ||
    die "backup.mode in $TFVARS has no copy destination; nothing to copy back from"
  role="arn:aws:iam::${backup_account}:role/${RESTORE_ROLE_NAME}"

  lifecycle="$(resolve_plan_retention "$REGION")"
  retention="$(printf '%s' "$lifecycle" | cut -f1)"

  log "Copying $rp back from $dest_vault ($BACKUP_REGION) to $VAULT ($REGION)..."
  log "This is roughly 60x slower than the outbound direction: budget 4-6 HOURS,"
  log "sitting in CREATED with no status message the whole time. That is"
  log "documented AWS Backup behavior, not a hang -- do not conclude anything"
  log "from a short poll, and do not delete $VAULT while this is queued."
  confirm "Start the copy back?"

  job="$(aws_as "$BACKUP_PROFILE" backup start-copy-job --region "$BACKUP_REGION" \
    --source-backup-vault-name "$dest_vault" \
    --destination-backup-vault-arn "arn:aws:backup:${REGION}:${account}:backup-vault:${VAULT}" \
    --iam-role-arn "$role" --recovery-point-arn "$rp" \
    --lifecycle "DeleteAfterDays=$retention" --query 'CopyJobId' --output text)"
  log "Copy job started: $job"
  poll_job "Copy back" "$COPY_BACK_TICKS" "$job" copy "$BACKUP_REGION" "$BACKUP_PROFILE"

  dest_rp="$(aws_as "$BACKUP_PROFILE" backup describe-copy-job --region "$BACKUP_REGION" \
    --copy-job-id "$job" --query 'CopyJob.DestinationRecoveryPointArn' --output text)"
  log "Landed in $VAULT as $dest_rp -- restoring it into the workload account..."

  restore_landed_rp "$dest_rp"
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
  local mode locked
  mode="$(backup_field mode local)"
  [ "$mode" = cross_account ] ||
    die "backup.mode is '$mode' in $TFVARS, not cross_account; the drill only
applies to the cross-account pipeline (docs/cross-account-backup.md)."

  DRILL_ACCOUNT="$(resolve_account)"
  DRILL_BACKUP_ACCOUNT="$(resolve_backup_account)"
  DRILL_VAULT="$(tf_output_opt backup_vault_name)"
  [ -n "$DRILL_VAULT" ] || die "no backup vault for '$ENV'; is the stack applied?"
  DRILL_DEST_VAULT="$(backup_field dest_vault_name gramps-web-backup-replica)"

  locked="$(aws_as "$BACKUP_PROFILE" backup describe-backup-vault --region "$BACKUP_REGION" \
    --backup-vault-name "$DRILL_DEST_VAULT" --query Locked --output text 2>/dev/null || echo false)"
  [ "$locked" != "True" ] ||
    die "$DRILL_DEST_VAULT is already locked. The drill creates recovery points
it must delete afterward; a locked vault won't allow that. Run the drill
BEFORE locking (docs/cross-account-backup.md)."

  log "Preflight OK: workload=$DRILL_ACCOUNT ($REGION), backup=$DRILL_BACKUP_ACCOUNT ($BACKUP_REGION)"
  log "Vault: $DRILL_DEST_VAULT (unlocked)"
}

drill_seed() {
  local role dest primary_arn primary_label s3_arn tags
  role="arn:aws:iam::${DRILL_ACCOUNT}:role/${BACKUP_ROLE_NAME}"
  dest="$(resolve_dest_vault_arn)"
  primary_label="EBS"
  primary_arn="$(volume_arn "$REGION" "$(tf_output ebs_volume_id)")"
  s3_arn="$(tf_output media_bucket_arn)"

  # DRILL_RETENTION_DAYS, not the live plan's production retention: these
  # recovery points are throwaway, and a short lifecycle is the backstop when
  # drill-cleanup can't remove them (see the constant's own comment above).
  log "Seeding recovery points for the drill (crash-consistent, no downtime)..."
  tags="{\"Project\":\"gramps-web\",\"Name\":\"$DRILL_TAG\"}"

  # Both jobs start before either is waited on -- same reasoning as
  # backup.sh run: the S3 half is the long pole.
  DRILL_PRIMARY_JOB="$(aws backup start-backup-job --region "$REGION" \
    --backup-vault-name "$DRILL_VAULT" --resource-arn "$primary_arn" --iam-role-arn "$role" \
    --lifecycle "DeleteAfterDays=$DRILL_RETENTION_DAYS" --recovery-point-tags "$tags" \
    --query 'BackupJobId' --output text)"
  DRILL_S3_JOB="$(aws backup start-backup-job --region "$REGION" \
    --backup-vault-name "$DRILL_VAULT" --resource-arn "$s3_arn" --iam-role-arn "$role" \
    --lifecycle "DeleteAfterDays=$DRILL_RETENTION_DAYS" --recovery-point-tags "$tags" \
    --query 'BackupJobId' --output text)"
  log "Backup jobs started: $primary_label=$DRILL_PRIMARY_JOB S3=$DRILL_S3_JOB"
  log "The S3 job sits at 0% for most of 20-30 min -- not a hang (backup.sh run"
  log "documents the same AWS Backup behavior)."

  poll_job "Seed $primary_label backup" "$BACKUP_TICKS" "$DRILL_PRIMARY_JOB" backup "$REGION"
  poll_job "Seed S3 backup" "$BACKUP_TICKS" "$DRILL_S3_JOB" backup "$REGION"

  DRILL_PRIMARY_RP="$(aws backup describe-backup-job --region "$REGION" \
    --backup-job-id "$DRILL_PRIMARY_JOB" --query RecoveryPointArn --output text)"
  DRILL_S3_RP="$(aws backup describe-backup-job --region "$REGION" \
    --backup-job-id "$DRILL_S3_JOB" --query RecoveryPointArn --output text)"
  log "Local recovery points: $primary_label=$DRILL_PRIMARY_RP S3=$DRILL_S3_RP"

  DRILL_PRIMARY_COPY_JOB="$(aws backup start-copy-job --region "$REGION" \
    --source-backup-vault-name "$DRILL_VAULT" --destination-backup-vault-arn "$dest" \
    --iam-role-arn "$role" --recovery-point-arn "$DRILL_PRIMARY_RP" \
    --lifecycle "DeleteAfterDays=$DRILL_RETENTION_DAYS" --query 'CopyJobId' --output text)"
  DRILL_S3_COPY_JOB="$(aws backup start-copy-job --region "$REGION" \
    --source-backup-vault-name "$DRILL_VAULT" --destination-backup-vault-arn "$dest" \
    --iam-role-arn "$role" --recovery-point-arn "$DRILL_S3_RP" \
    --lifecycle "DeleteAfterDays=$DRILL_RETENTION_DAYS" --query 'CopyJobId' --output text)"
  poll_job "Outbound $primary_label copy" "$COPY_TICKS" "$DRILL_PRIMARY_COPY_JOB" copy "$REGION"
  poll_job "Outbound S3 copy" "$COPY_TICKS" "$DRILL_S3_COPY_JOB" copy "$REGION"

  DRILL_DEST_PRIMARY_RP="$(aws backup describe-copy-job --region "$REGION" \
    --copy-job-id "$DRILL_PRIMARY_COPY_JOB" --query 'CopyJob.DestinationRecoveryPointArn' --output text)"
  DRILL_DEST_S3_RP="$(aws backup describe-copy-job --region "$REGION" \
    --copy-job-id "$DRILL_S3_COPY_JOB" --query 'CopyJob.DestinationRecoveryPointArn' --output text)"
  log "PASS: outbound KMS grants and the copy pipeline work, for both resource types."
  log "  $primary_label landed as $DRILL_DEST_PRIMARY_RP"
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
  local role az meta job size status stats r_count r_bytes live_stats l_count l_bytes media_bucket

  role="arn:aws:iam::${DRILL_BACKUP_ACCOUNT}:role/${RESTORE_ROLE_NAME}"

  az="$(aws_as "$BACKUP_PROFILE" ec2 describe-availability-zones --region "$BACKUP_REGION" \
    --query 'AvailabilityZones[0].ZoneName' --output text)"

  meta="$(restore_metadata "$DRILL_DEST_VAULT" "$DRILL_DEST_PRIMARY_RP" "$BACKUP_REGION" "$az" "$BACKUP_PROFILE")"
  job="$(aws_as "$BACKUP_PROFILE" backup start-restore-job --region "$BACKUP_REGION" \
    --recovery-point-arn "$DRILL_DEST_PRIMARY_RP" --iam-role-arn "$role" \
    --resource-type EBS --metadata "$meta" --query 'RestoreJobId' --output text)"
  poll_job "Offsite EBS restore" "$RESTORE_TICKS" "$job" restore "$BACKUP_REGION" "$BACKUP_PROFILE"

  DRILL_OFFSITE_PRIMARY="$(aws_as "$BACKUP_PROFILE" backup describe-restore-job --region "$BACKUP_REGION" \
    --restore-job-id "$job" --query 'CreatedResourceArn' --output text | awk -F/ '{print $NF}')"
  size="$(aws_as "$BACKUP_PROFILE" ec2 describe-volumes --region "$BACKUP_REGION" \
    --volume-ids "$DRILL_OFFSITE_PRIMARY" --query 'Volumes[0].Size' --output text)"
  case "$size" in
  [1-9]*) ;;
  *) die "restored volume $DRILL_OFFSITE_PRIMARY reports size '$size', not a positive
number of GiB -- the recovery point may be empty." ;;
  esac
  log "PASS (EBS): restored to $DRILL_OFFSITE_PRIMARY ($BACKUP_REGION, $az, ${size}GiB) --"
  log "the destination CMK and the restore role both work. Size only -- see the"
  log "header for why full content verification is a manual exercise here."

  DRILL_SCRATCH_BUCKET="$(create_scratch_bucket "$BACKUP_PROFILE" "$BACKUP_REGION")"
  restore_s3_to_scratch "$DRILL_DEST_VAULT" "$DRILL_DEST_S3_RP" "$BACKUP_REGION" "$role" \
    "$DRILL_SCRATCH_BUCKET" "$BACKUP_PROFILE"

  # An S3 recovery point reports BackupSizeInBytes: 0 -- count what actually
  # landed instead of trusting the recovery point's own metadata.
  stats="$(s3_object_stats "$BACKUP_PROFILE" "$BACKUP_REGION" "$DRILL_SCRATCH_BUCKET")"
  r_count="$(printf '%s' "$stats" | cut -f1)"
  r_bytes="$(printf '%s' "$stats" | cut -f2)"

  media_bucket="$(tf_output media_bucket_name)"
  live_stats="$(s3_object_stats "" "$REGION" "$media_bucket")"
  l_count="$(printf '%s' "$live_stats" | cut -f1)"
  l_bytes="$(printf '%s' "$live_stats" | cut -f2)"

  [ "$r_count" = "$l_count" ] && [ "$r_bytes" = "$l_bytes" ] ||
    die "FAIL (S3): restored $DRILL_SCRATCH_BUCKET has $r_count objects /
$r_bytes bytes, but the live bucket $media_bucket has $l_count objects /
$l_bytes bytes. Content did not land intact."
  log "PASS (S3): restored $r_count objects / $r_bytes bytes into"
  log "$DRILL_SCRATCH_BUCKET, matching the live bucket exactly -- real content"
  log "proof, no compute needed."
}

# drill_negative_test RP LABEL: the workload account, using its OWN default
# credentials (not BACKUP_PROFILE), attempts to delete RP from the
# DESTINATION vault it does not own. AccessDeniedException is the pass -- the
# vault policy grants it CopyIntoBackupVault and nothing else
# (aws_backup_vault_policy.replica, terraform/roots/backup-account/vault.tf).
# Run once per resource type: the isolation guarantee has to hold for both.
drill_negative_test() {
  local rp label out status
  rp="$1"
  label="$2"
  set +e
  out="$(aws backup delete-recovery-point --region "$BACKUP_REGION" \
    --backup-vault-name "$DRILL_DEST_VAULT" --recovery-point-arn "$rp" 2>&1)"
  status=$?
  set -e
  [ "$status" -ne 0 ] ||
    die "FAIL ($label): the workload account deleted $rp from $DRILL_DEST_VAULT --
the isolation this design exists for is not real. Check
aws_backup_vault_policy.replica in terraform/roots/backup-account/vault.tf."
  case "$out" in
  *AccessDenied*)
    log "PASS ($label): the workload account cannot delete from $DRILL_DEST_VAULT (AccessDeniedException, as designed)"
    ;;
  *)
    die "drill inconclusive ($label): delete-recovery-point failed, but not with
AccessDenied: $out"
    ;;
  esac
}

drill_write_manifest() {
  local manifest
  manifest="$SCRIPT_DIR/restore-drill-$(date -u +%Y%m%d%H%M%S).json"
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
    >"$manifest"
  echo "$manifest"
}

cmd_drill() {
  local manifest
  [ "$#" -eq 0 ] || die "usage: $0 drill"

  drill_preflight
  drill_seed
  drill_confirm_landing
  drill_restore_offsite
  drill_negative_test "$DRILL_DEST_PRIMARY_RP" EBS
  drill_negative_test "$DRILL_DEST_S3_RP" S3

  manifest="$(drill_write_manifest)"
  log ""
  log "=== DRILL PASSED ==="
  log "Artifacts recorded in $manifest."
  log "Run '$0 drill-cleanup' BEFORE locking the vault -- a locked vault"
  log "cannot delete what this drill just created. If the protective SCPs"
  log "from docs/cross-account-backup.md are already attached, cleanup may"
  log "not be able to remove the destination recovery points either -- they"
  log "are on a $DRILL_RETENTION_DAYS-day lifecycle and expire on their own regardless."
  log "Once cleanup is done, lock it (docs/cross-account-backup.md):"
  log "  vault_lock = { mode = \"governance\", min_retention_days = 7, max_retention_days = 365 }"
  log "  AWS_PROFILE=$BACKUP_PROFILE scripts/tf.sh backup-account/<instance> apply"
}

# CLEANUP_ERR: set by the delete_* helpers on
# failure, read by explain_cleanup_failure. A plain global (not `local`)
# since it crosses from a helper's return status back to its caller's log
# message.
CLEANUP_ERR=""

# delete_offsite_volume REGION VOL: 0 if deleted or already gone, 1
# otherwise (CLEANUP_ERR set).
delete_offsite_volume() {
  local out status
  out="$(aws_as "$BACKUP_PROFILE" ec2 delete-volume --region "$1" --volume-id "$2" 2>&1)"
  status=$?
  [ "$status" -eq 0 ] && return 0
  case "$out" in
  *InvalidVolume.NotFound*) return 0 ;; # already gone -- idempotent success
  esac
  CLEANUP_ERR="$out"
  return 1
}

# delete_recovery_point PROFILE REGION VAULT RP: 0 if deleted or already
# gone, 1 otherwise (CLEANUP_ERR set). PROFILE may be empty (workload
# account, no override -- see aws_as).
delete_recovery_point() {
  local out status
  out="$(aws_as "$1" backup delete-recovery-point --region "$2" \
    --backup-vault-name "$3" --recovery-point-arn "$4" 2>&1)"
  status=$?
  [ "$status" -eq 0 ] && return 0
  case "$out" in
  *ResourceNotFoundException* | *"Cannot find recovery point"*) return 0 ;;
  esac
  CLEANUP_ERR="$out"
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
  local manifest
  local local_primary_rp dest_primary_rp local_s3_rp dest_s3_rp dest_vault backup_region offsite_primary
  local local_primary_done dest_primary_done local_s3_done dest_s3_done offsite_done all_done
  [ "$#" -le 1 ] || die "usage: $0 drill-cleanup [manifest]"
  manifest="${1:-}"
  if [ -z "$manifest" ]; then
    manifest="$(find "$SCRIPT_DIR" -maxdepth 1 -name 'restore-drill-*.json' 2>/dev/null | sort | tail -n 1)"
  fi
  [ -f "$manifest" ] ||
    die "no drill manifest found. Pass one explicitly, or run '$0 drill' first."
  [ -n "$BACKUP_PROFILE" ] ||
    die "BACKUP_PROFILE not set; drill-cleanup needs the backup account's own credentials"

  local_primary_rp="$(jq -r '.local_primary_recovery_point // ""' "$manifest")"
  dest_primary_rp="$(jq -r '.destination_primary_recovery_point // ""' "$manifest")"
  local_s3_rp="$(jq -r '.local_s3_recovery_point // ""' "$manifest")"
  dest_s3_rp="$(jq -r '.destination_s3_recovery_point // ""' "$manifest")"
  dest_vault="$(jq -r '.destination_vault // ""' "$manifest")"
  backup_region="$(jq -r '.backup_region // ""' "$manifest")"
  offsite_primary="$(jq -r '.offsite_primary_resource // ""' "$manifest")"
  # Per-artifact flags: a missing flag in an older manifest just means
  # "nothing confirmed deleted yet" -- a harmless retry of whatever remains.
  local_primary_done="$(jq -r '.local_primary_recovery_point_deleted // false' "$manifest")"
  dest_primary_done="$(jq -r '.destination_primary_recovery_point_deleted // false' "$manifest")"
  local_s3_done="$(jq -r '.local_s3_recovery_point_deleted // false' "$manifest")"
  dest_s3_done="$(jq -r '.destination_s3_recovery_point_deleted // false' "$manifest")"
  offsite_done="$(jq -r '.offsite_primary_resource_deleted // false' "$manifest")"

  VAULT="$(tf_output_opt backup_vault_name)"

  log "Manifest: $manifest (EBS)"
  log "  local EBS recovery point:       ${local_primary_rp:-(none)}"
  log "  destination EBS recovery point: ${dest_primary_rp:-(none)}"
  log "  local S3 recovery point:        ${local_s3_rp:-(none)}"
  log "  destination S3 recovery point:  ${dest_s3_rp:-(none)}"
  log "  offsite scratch EBS resource:    ${offsite_primary:-(none)}"
  confirm "Delete what's left of these drill artifacts?"

  if [ -z "$offsite_primary" ] || [ "$offsite_primary" = null ]; then
    offsite_done=true
  elif [ "$offsite_done" != true ]; then
    if delete_offsite_volume "$backup_region" "$offsite_primary"; then
      offsite_done=true
      log "  offsite volume $offsite_primary: deleted (or already gone)"
    else
      explain_cleanup_failure "offsite volume $offsite_primary"
    fi
  fi

  if [ -z "$dest_primary_rp" ] || [ "$dest_primary_rp" = null ]; then
    dest_primary_done=true
  elif [ "$dest_primary_done" != true ]; then
    if delete_recovery_point "$BACKUP_PROFILE" "$backup_region" "$dest_vault" "$dest_primary_rp"; then
      dest_primary_done=true
      log "  destination EBS recovery point $dest_primary_rp: deleted (or already gone)"
    else
      explain_cleanup_failure "destination EBS recovery point $dest_primary_rp"
    fi
  fi

  if [ -z "$dest_s3_rp" ] || [ "$dest_s3_rp" = null ]; then
    dest_s3_done=true
  elif [ "$dest_s3_done" != true ]; then
    if delete_recovery_point "$BACKUP_PROFILE" "$backup_region" "$dest_vault" "$dest_s3_rp"; then
      dest_s3_done=true
      log "  destination S3 recovery point $dest_s3_rp: deleted (or already gone)"
    else
      explain_cleanup_failure "destination S3 recovery point $dest_s3_rp"
    fi
  fi

  if [ -z "$local_primary_rp" ] || [ "$local_primary_rp" = null ] || [ -z "$VAULT" ]; then
    local_primary_done=true
  elif [ "$local_primary_done" != true ]; then
    if delete_recovery_point "" "$REGION" "$VAULT" "$local_primary_rp"; then
      local_primary_done=true
      log "  local EBS recovery point $local_primary_rp: deleted (or already gone)"
    else
      explain_cleanup_failure "local EBS recovery point $local_primary_rp"
    fi
  fi

  if [ -z "$local_s3_rp" ] || [ "$local_s3_rp" = null ] || [ -z "$VAULT" ]; then
    local_s3_done=true
  elif [ "$local_s3_done" != true ]; then
    if delete_recovery_point "" "$REGION" "$VAULT" "$local_s3_rp"; then
      local_s3_done=true
      log "  local S3 recovery point $local_s3_rp: deleted (or already gone)"
    else
      explain_cleanup_failure "local S3 recovery point $local_s3_rp"
    fi
  fi

  if [ "$local_primary_done" = true ] && [ "$dest_primary_done" = true ] &&
    [ "$local_s3_done" = true ] && [ "$dest_s3_done" = true ] &&
    [ "$offsite_done" = true ]; then
    all_done=true
  else
    all_done=false
  fi

  jq --argjson local_primary_done "$local_primary_done" --argjson dest_primary_done "$dest_primary_done" \
    --argjson local_s3_done "$local_s3_done" --argjson dest_s3_done "$dest_s3_done" \
    --argjson offsite_done "$offsite_done" \
    --argjson cleaned "$all_done" \
    '.local_primary_recovery_point_deleted = $local_primary_done
     | .destination_primary_recovery_point_deleted = $dest_primary_done
     | .local_s3_recovery_point_deleted = $local_s3_done
     | .destination_s3_recovery_point_deleted = $dest_s3_done
     | .offsite_primary_resource_deleted = $offsite_done
     | .cleaned = $cleaned' \
    "$manifest" >"$manifest.tmp" && mv "$manifest.tmp" "$manifest"

  if [ "$all_done" = true ]; then
    log "Cleanup done. Verify: $0 list"
  else
    log "Cleanup incomplete -- see above for what's blocking it and why."
    log "Re-run '$0 drill-cleanup $manifest' to retry; anything already"
    log "deleted is skipped."
  fi
}

# --- dispatch ----------------------------------------------------------------

main() {
  local cmd
  require aws terraform jq
  [ "$#" -ge 1 ] || usage
  cmd="$1"
  shift
  case "$cmd" in
  list) cmd_list "$@" ;;
  local) cmd_local "$@" ;;
  offsite) cmd_offsite "$@" ;;
  copy-back) cmd_copy_back "$@" ;;
  drill) cmd_drill "$@" ;;
  drill-cleanup) cmd_drill_cleanup "$@" ;;
  *) die "unknown subcommand '$cmd' (expected: list|local|offsite|copy-back|drill|drill-cleanup)" ;;
  esac
}

main "$@"
