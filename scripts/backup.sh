#!/bin/sh
# On-demand backups of the irreplaceable data: the EBS data volume (tree DB,
# search index, users, secret) and the S3 media bucket (photo/document
# originals).
#
# The daily AWS Backup plan (modules/storage/backup.tf) already takes a
# crash-consistent recovery point of both at 03:00 UTC and copies it wherever
# the backup tfvars object points. This script is for what a schedule cannot
# do: take a restore point RIGHT NOW, and take an APP-CONSISTENT one.
#
#   ./backup.sh snapshot [reason]  Raw snapshot of the data volume.
#                                  App-consistent, ~30-60s of downtime. Local
#                                  only.
#   ./backup.sh run [reason]       AWS Backup job for BOTH resources into the
#                                  vault, then copied off-site. Crash-consistent,
#                                  no downtime, ~30 min (the S3 half is slow).
#   ./backup.sh status             Recent jobs, what is in the local vault, and
#                                  any `snapshot` output still lying around.
#
# Picking one:
#
#   snapshot  Before a risky change you might undo within the hour: an app
#             upgrade (which runs DB schema migrations), a bulk import, manual
#             surgery. It is the only path that stops the writers first, so it
#             is the only one that captures a quiet filesystem. It is also the
#             only one that is neither off-site nor on a retention clock --
#             delete it yourself; `status` lists what has piled up.
#
#   run       When you want a real, off-site, retention-managed recovery point
#             without waiting for 03:00: seeding the pipeline after a migration
#             (docs/cross-account-backup.md step 5), or re-proving the copy path
#             still works.
#
# Why `run` does NOT stop the app, though it is the more thorough backup:
# `snapshot` can restart the app the moment create-snapshot returns, because
# that call closes the snapshot's point-in-time synchronously. start-backup-job
# only QUEUES a job, and nothing in its API says when the underlying snapshot's
# point-in-time closes -- holding the site down for it would mean inferring that
# from undocumented job-state transitions. So `run` is crash-consistent on
# purpose: the same consistency the daily plan takes, and the same a Spot
# reclaim leaves behind (build/ami/spot-drain.sh). If you need
# app-consistency, that is what `snapshot` is for.
#
# Two AWS Backup behaviours `run` encodes so you do not have to remember them:
#   - copy_action fires for PLAN-driven jobs ONLY. An on-demand backup job lands
#     in the local vault and stops there; `run` issues the copy itself.
#   - A job started without --lifecycle produces a recovery point that NEVER
#     expires -- silently permanent in the local vault, rejected outright by the
#     locked destination. `run` passes the stack's retention on both halves.
#
# `run` and `status` need the workload account's ADMIN profile: reading
# Terraform outputs decrypts state, which ReadOnly cannot do. Both check the
# account up front, because the failure otherwise surfaces as an
# AccessDeniedException from start-backup-job rather than anything about
# credentials.
#
# Restores are deliberately not here: scripts/restore.sh (docs/restore.md)
# covers every recovery scenario, including the restore drill that gates
# locking the destination vault (docs/cross-account-backup.md). Adopting a
# restored volume into the live stack is scripts/azmove.sh (docs/az-move.md).
#
# Env: ENV (default prod; selects terraform/config/stack/<env>), AWS_REGION
#      (default: primary_region from the env's tfvars), FORCE=1 (skip prompts).
set -eu

SCRIPT_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly SCRIPT_DIR
REPO_ROOT="$(dirname -- "$SCRIPT_DIR")"
readonly REPO_ROOT

readonly LOG_PREFIX="backup"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

env_paths
REGION="$(resolve_region "$TFVARS")"
readonly REGION

# The role and plan modules/storage/backup.tf declares. Repo constants, as in
# deploy.sh: neither is worth an output, and a name mismatch fails loudly rather
# than silently (start-backup-job 404s on the role; resolve_plan dies on the plan).
readonly BACKUP_ROLE_NAME="gramps-web-backup"
readonly BACKUP_PLAN_NAME="gramps-web-daily"

# Job polling. The S3 half of `run` is the long pole: 20-30 min even at this
# size, because AWS Backup's S3 jobs are dominated by fixed per-job setup rather
# than by data. 240 x 15s = 60 min gives it room without hanging forever.
# Copies outbound are 2-5 min; 80 x 15s = 20 min is generous. (A copy BACK would
# be 4-6 HOURS -- see docs/cross-account-backup.md -- but this script never
# issues one.)
readonly POLL_SECONDS=15
readonly BACKUP_TICKS=240
readonly COPY_TICKS=80
# Heartbeat every 8th tick (~2 min), so a job that sits at one state for half an
# hour still shows a pulse without spamming 240 lines.
readonly HEARTBEAT_EVERY=8

# Cross-function state: the EXIT trap needs both to decide whether the site
# was left down.
APP_STOPPED=0
INSTANCE_ID=""

# --- snapshot ----------------------------------------------------------------

start_app() {
  log "Restarting the app containers..."
  ssm_run "$INSTANCE_ID" "gramps backup: restart app" "$START_CMD"
}

# EXIT trap: if anything dies between stop and restart, bring the site back
# up before exiting. `up -d` is idempotent, so a spurious restart is a no-op.
cleanup() {
  local status
  status=$?
  if [ "$APP_STOPPED" = 1 ]; then
    log "Backup did not complete cleanly; bringing the app back up..."
    start_app ||
      log "ERROR: restart failed. On the instance, run: $START_CMD"
  fi
  exit "$status"
}

# Written before the app stops so the availability Lambda attributes the
# outage to this snapshot (the parameter is modules/compute's
# last_backup_snapshot).
mark_backup() {
  aws ssm put-parameter --region "$REGION" \
    --name "/gramps-web/$ENV/last-backup-snapshot" \
    --type String --overwrite \
    --value "$(jq -n --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg i "$INSTANCE_ID" \
      '{time: $t, instance_id: $i}')" >/dev/null
}

# $1 = volume id. Stop the two writers on the attached instance so the
# snapshot is app-consistent. Sets INSTANCE_ID and APP_STOPPED.
quiesce_app() {
  local ping
  INSTANCE_ID="$(aws ec2 describe-volumes --region "$REGION" \
    --volume-ids "$1" \
    --query 'Volumes[0].Attachments[0].InstanceId' --output text)"
  ping="$(aws ssm describe-instance-information --region "$REGION" \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --query 'InstanceInformationList[0].PingStatus' \
    --output text 2>/dev/null || echo None)"
  [ "$ping" = "Online" ] ||
    die "cannot quiesce: $INSTANCE_ID is not reachable over SSM (ping: $ping).
For a crash-consistent recovery point instead, with no downtime and off-site:
  $0 run"

  confirm "Stop the app on $INSTANCE_ID for a consistent snapshot? (THE SITE GOES DOWN for ~30-60s)"
  mark_backup ||
    log "WARNING: could not write the cause marker; the status page will not label this downtime a backup."
  log "Stopping the app containers (the writers on the volume)..."
  APP_STOPPED=1
  ssm_run "$INSTANCE_ID" "gramps backup: stop app" "$STOP_CMD" ||
    die "could not stop the app cleanly; not snapshotting"
}

# create_snapshot VOLUME REASON -> snapshot id on stdout. Its point-in-time is
# locked in as soon as this returns, so the app can restart before the upload.
create_snapshot() {
  local ts
  ts="$(date -u +%Y%m%d%H%M%S)"
  aws ec2 create-snapshot --region "$REGION" --volume-id "$1" \
    --description "on-demand backup $ts${2:+: $2}" \
    --tag-specifications "ResourceType=snapshot,Tags=[{Key=Project,Value=gramps-web},{Key=Name,Value=gramps-data-ondemand}]" \
    --query 'SnapshotId' --output text
}

# $1 = snapshot id. The upload runs server-side; the app is already back up.
wait_for_snapshot() {
  local state
  log "Waiting for $1 to complete (upload runs server-side)..."
  if aws ec2 wait snapshot-completed --region "$REGION" --snapshot-ids "$1"; then
    return 0
  fi
  state="$(aws ec2 describe-snapshots --region "$REGION" \
    --snapshot-ids "$1" --query 'Snapshots[0].State' --output text)"
  [ "$state" != "error" ] ||
    die "snapshot $1 failed (state: error); NO backup exists"
  die "snapshot $1 still '$state' after ~10 min; the app is back up. Re-check with:
  aws ec2 wait snapshot-completed --region $REGION --snapshot-ids $1"
}

cmd_snapshot() {
  local reason vol state snap
  [ "$#" -le 1 ] || die "usage: $0 snapshot [reason]"
  reason="${1:-}"

  vol="$(tf_output ebs_volume_id)"
  state="$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$vol" \
    --query 'Volumes[0].State' --output text)"

  trap cleanup EXIT

  case "$state" in
  available) log "Volume $vol is detached: snapshotting cold, no downtime." ;;
  in-use) quiesce_app "$vol" ;;
  *) die "volume $vol is in state '$state'; refusing to snapshot" ;;
  esac

  log "Creating snapshot of $vol..."
  snap="$(create_snapshot "$vol" "$reason")"
  log "Snapshot $snap initiated; its point-in-time is now locked in."

  if [ "$APP_STOPPED" = 1 ]; then
    start_app
    APP_STOPPED=0
  fi

  wait_for_snapshot "$snap"
  log "Backup complete: $snap"
  log "This snapshot is local-only and on NO retention clock; delete it when stale:"
  log "  aws ec2 delete-snapshot --region $REGION --snapshot-id $snap"
  log "To restore it into a volume, see docs/az-move.md."
}

# --- run ---------------------------------------------------------------------

# start_backup_job RESOURCE_ARN LABEL REASON RETENTION -> backup job id.
# --lifecycle is not optional: without it the recovery point never expires.
start_backup_job() {
  local tags
  tags="$(jq -n --arg r "$3" '
    {Project: "gramps-web", Name: "gramps-web-ondemand"}
    + (if $r == "" then {} else {Reason: $r} end)')"
  log "Starting backup job: $2 (retention ${4}d)"
  aws backup start-backup-job --region "$REGION" \
    --backup-vault-name "$VAULT" \
    --resource-arn "$1" \
    --iam-role-arn "$ROLE" \
    --lifecycle "DeleteAfterDays=$4" \
    --recovery-point-tags "$tags" \
    --query 'BackupJobId' --output text
}

# start_copy_job RECOVERY_POINT_ARN LABEL RETENTION -> copy job id.
# Note there is NO --resource-arn here, unlike start-backup-job: the recovery
# point ARN already identifies the resource, and passing one is an "Unknown
# options" error. --lifecycle is again mandatory in practice -- omitted, the
# copy is rejected outright by the locked destination vault.
start_copy_job() {
  log "Starting copy job: $2 (remote retention ${3}d)"
  aws backup start-copy-job --region "$REGION" \
    --source-backup-vault-name "$VAULT" \
    --destination-backup-vault-arn "$DEST" \
    --iam-role-arn "$ROLE" \
    --recovery-point-arn "$1" \
    --lifecycle "DeleteAfterDays=$3" \
    --query 'CopyJobId' --output text
}

# $1 = completed backup job id -> the recovery point ARN it produced.
job_recovery_point() {
  aws backup describe-backup-job --region "$REGION" --backup-job-id "$1" \
    --query 'RecoveryPointArn' --output text
}

cmd_run() {
  local reason account lifecycle retention remote_retention
  local primary_label primary_arn s3_arn primary_job s3_job primary_rp s3_rp primary_copy s3_copy
  [ "$#" -le 1 ] || die "usage: $0 run [reason]"
  reason="${1:-}"

  account="$(resolve_account)"
  ROLE="arn:aws:iam::${account}:role/${BACKUP_ROLE_NAME}"
  readonly ROLE

  VAULT="$(tf_output_opt backup_vault_name)"
  readonly VAULT
  [ -n "$VAULT" ] ||
    die "no backup vault for '$ENV': backup.mode is 'disabled' in $TFVARS
(or the stack is not applied). Nothing to back up into."

  DEST="$(tf_output_opt backup_copy_vault_arn)"
  readonly DEST

  lifecycle="$(resolve_plan_retention "$REGION")"
  retention="$(printf '%s' "$lifecycle" | cut -f1)"
  remote_retention="$(printf '%s' "$lifecycle" | cut -f2)"
  # Belt and braces: a copy destination with no copy_action retention would mean
  # the plan and the stack's mode disagree, and copying without a retention is
  # the one mistake this script exists to prevent.
  [ -z "$DEST" ] || [ "$remote_retention" != None ] ||
    die "plan '$BACKUP_PLAN_NAME' has no copy_action retention, but the stack
declares a copy destination ($DEST). Apply the '$ENV' stack before running this."

  primary_label="EBS data volume"
  primary_arn="$(tf_output ebs_volume_arn)"
  s3_arn="$(tf_output media_bucket_arn)"

  log "Vault:   $VAULT ($REGION, account $account)"
  if [ -n "$DEST" ]; then
    log "Copy to: $DEST"
  else
    log "Copy to: (none -- backup.mode is 'local'; this recovery point stays in"
    log "         this account and region)"
  fi
  log "This is CRASH-consistent, like the daily plan. The site stays up."
  log "For an app-consistent point instead, see: $0 snapshot"
  confirm "Take an on-demand recovery point of the $primary_label and the media bucket?"

  # Both jobs start before either is waited on: the S3 half runs 20-30 min
  # and the primary half a few, so serialising them would add the primary's
  # time for nothing.
  primary_job="$(start_backup_job "$primary_arn" "$primary_label" "$reason" "$retention")"
  s3_job="$(start_backup_job "$s3_arn" "S3 media bucket" "$reason" "$retention")"

  log "Backup jobs started: $primary_label=$primary_job S3=$s3_job"
  log "The S3 job sits at 0% for most of 20-30 min -- AWS Backup's S3 jobs are"
  log "dominated by fixed per-job setup, not by data. That is not a hang."

  poll_job "$primary_label backup" "$BACKUP_TICKS" "$primary_job" backup "$REGION"
  poll_job "S3 media bucket backup" "$BACKUP_TICKS" "$s3_job" backup "$REGION"

  primary_rp="$(job_recovery_point "$primary_job")"
  s3_rp="$(job_recovery_point "$s3_job")"
  log "Recovery points in $VAULT:"
  log "  $primary_label: $primary_rp"
  log "  S3:  $s3_rp"

  if [ -z "$DEST" ]; then
    log "Done. No copy configured (backup.mode = local)."
    return 0
  fi

  # The copy is this script's job, not the plan's: copy_action fires for
  # plan-driven jobs only, so these recovery points would otherwise expire in
  # the local vault having never gone off-site -- which would make an on-demand
  # backup silently weaker than a scheduled one, in the one way that matters.
  primary_copy="$(start_copy_job "$primary_rp" "$primary_label" "$remote_retention")"
  s3_copy="$(start_copy_job "$s3_rp" "S3 media bucket" "$remote_retention")"

  log "Copy jobs started: $primary_label=$primary_copy S3=$s3_copy (outbound runs 2-5 min)"
  poll_job "$primary_label copy" "$COPY_TICKS" "$primary_copy" copy "$REGION"
  poll_job "S3 media bucket copy" "$COPY_TICKS" "$s3_copy" copy "$REGION"

  log "Done. Both resources are backed up locally and copied to:"
  log "  $DEST"
  log "Local copies expire in ${retention}d, remote in ${remote_retention}d."
  # `status` cannot show the far side: listing another account's vault needs
  # that account's credentials, which is the isolation working as designed.
  log "Confirm the far side from the DESTINATION account's profile:"
  log "  AWS_PROFILE=<backup-admin> aws backup list-recovery-points-by-backup-vault \\"
  log "    --backup-vault-name $(printf '%s' "$DEST" | cut -d: -f7) \\"
  log "    --region $(printf '%s' "$DEST" | cut -d: -f4)"
}

# --- status ------------------------------------------------------------------

cmd_status() {
  local vault dest snaps
  [ "$#" -eq 0 ] || die "usage: $0 status"

  vault="$(tf_output_opt backup_vault_name)"
  [ -n "$vault" ] ||
    die "no backup vault for '$ENV': backup.mode is 'disabled' in $TFVARS."
  dest="$(tf_output_opt backup_copy_vault_arn)"

  log "=== Recent backup jobs ($vault, $REGION) ==="
  aws backup list-backup-jobs --region "$REGION" \
    --by-backup-vault-name "$vault" --max-results 10 \
    --query 'reverse(sort_by(BackupJobs, &CreationDate))[].[CreationDate,ResourceType,State,PercentDone]' \
    --output table

  if [ -n "$dest" ]; then
    log "=== Recent copy jobs -> $dest ==="
    # A copy job stuck in CREATED here is the documented trap: outbound is
    # 2-5 min, but a copy BACK from the backup account runs 4-6 HOURS in
    # CREATED with no status message. Do not read CREATED as broken.
    aws backup list-copy-jobs --region "$REGION" \
      --by-destination-vault-arn "$dest" --max-results 10 \
      --query 'reverse(sort_by(CopyJobs, &CreationDate))[].[CreationDate,ResourceType,State,StatusMessage]' \
      --output table
  fi

  log "=== Recovery points in $vault ==="
  aws backup list-recovery-points-by-backup-vault --region "$REGION" \
    --backup-vault-name "$vault" \
    --query 'reverse(sort_by(RecoveryPoints, &CreationDate))[:10].[CreationDate,ResourceType,Status,RecoveryPointArn]' \
    --output table

  # The one thing here with no retention clock, so the one thing that silently
  # accumulates. Empty is the good state and is stated outright: `--output table`
  # prints NOTHING for an empty list, which reads as a broken command rather
  # than as "you have no stale snapshots".
  log "=== Raw on-demand snapshots from '$0 snapshot' (NO retention clock) ==="
  snaps="$(aws ec2 describe-snapshots --region "$REGION" --owner-ids self \
    --filters "Name=tag:Name,Values=gramps-data-ondemand" \
    --query 'reverse(sort_by(Snapshots, &StartTime))[].[StartTime,SnapshotId,State,Description]' \
    --output table)"
  if [ -n "$snaps" ]; then
    echo "$snaps"
    log "Delete any you no longer want: aws ec2 delete-snapshot --region $REGION --snapshot-id <id>"
  else
    log "(none -- nothing to clean up)"
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
  snapshot) cmd_snapshot "$@" ;;
  run) cmd_run "$@" ;;
  status) cmd_status "$@" ;;
  *) die "unknown subcommand '$cmd' (expected: snapshot|run|status)" ;;
  esac
}

main "$@"
