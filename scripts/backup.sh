#!/bin/sh
# On-demand backups of the irreplaceable data: the EBS data volume (tree DB,
# search index, users, secret) and the S3 media bucket (photo/document
# originals).
#
# The daily AWS Backup plan (modules/storage/backup.tf) already takes a
# crash-consistent recovery point of both at 03:00 UTC and copies it wherever
# the module's backup.mode points. This script is for what a schedule cannot
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
# Root: --root DIR, or $GRAMPS_WEB_ROOT, is the Terraform root that
#       instantiates the module (see common.sh). Place it before the subcommand.
# Env:  FORCE=1 (skip prompts).
set -eu

SCRIPT_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly SCRIPT_DIR

readonly LOG_PREFIX="backup"
# shellcheck source=keel/common.sh
. "$SCRIPT_DIR/keel/common.sh"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

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
  _cleanup_status=$?
  if [ "$APP_STOPPED" = 1 ]; then
    log "Backup did not complete cleanly; bringing the app back up..."
    start_app ||
      log "ERROR: restart failed. On the instance, run: $START_CMD"
  fi
  exit "$_cleanup_status"
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
  INSTANCE_ID="$(aws ec2 describe-volumes --region "$REGION" \
    --volume-ids "$1" \
    --query 'Volumes[0].Attachments[0].InstanceId' --output text)"
  _quiesce_app_ping="$(aws ssm describe-instance-information --region "$REGION" \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --query 'InstanceInformationList[0].PingStatus' \
    --output text 2>/dev/null || echo None)"
  [ "$_quiesce_app_ping" = "Online" ] ||
    die "cannot quiesce: $INSTANCE_ID is not reachable over SSM (ping: $_quiesce_app_ping).
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
  _create_snapshot_ts="$(date -u +%Y%m%d%H%M%S)"
  aws ec2 create-snapshot --region "$REGION" --volume-id "$1" \
    --description "on-demand backup $_create_snapshot_ts${2:+: $2}" \
    --tag-specifications "ResourceType=snapshot,Tags=[{Key=Project,Value=gramps-web},{Key=Name,Value=gramps-data-ondemand}]" \
    --query 'SnapshotId' --output text
}

# $1 = snapshot id. The upload runs server-side; the app is already back up.
wait_for_snapshot() {
  log "Waiting for $1 to complete (upload runs server-side)..."
  if aws ec2 wait snapshot-completed --region "$REGION" --snapshot-ids "$1"; then
    return 0
  fi
  _wait_for_snapshot_state="$(aws ec2 describe-snapshots --region "$REGION" \
    --snapshot-ids "$1" --query 'Snapshots[0].State' --output text)"
  [ "$_wait_for_snapshot_state" != "error" ] ||
    die "snapshot $1 failed (state: error); NO backup exists"
  die "snapshot $1 still '$_wait_for_snapshot_state' after ~10 min; the app is back up. Re-check with:
  aws ec2 wait snapshot-completed --region $REGION --snapshot-ids $1"
}

cmd_snapshot() {
  _cmd_snapshot_reason=""
  [ "$#" -le 1 ] || die "usage: $0 snapshot [reason]"
  _cmd_snapshot_reason="${1:-}"

  _cmd_snapshot_vol="$(tf_output ebs_volume_id)"
  _cmd_snapshot_state="$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$_cmd_snapshot_vol" \
    --query 'Volumes[0].State' --output text)"

  trap cleanup EXIT

  case "$_cmd_snapshot_state" in
  available) log "Volume $_cmd_snapshot_vol is detached: snapshotting cold, no downtime." ;;
  in-use) quiesce_app "$_cmd_snapshot_vol" ;;
  *) die "volume $_cmd_snapshot_vol is in state '$_cmd_snapshot_state'; refusing to snapshot" ;;
  esac

  log "Creating snapshot of $_cmd_snapshot_vol..."
  _cmd_snapshot_snap="$(create_snapshot "$_cmd_snapshot_vol" "$_cmd_snapshot_reason")"
  log "Snapshot $_cmd_snapshot_snap initiated; its point-in-time is now locked in."

  if [ "$APP_STOPPED" = 1 ]; then
    start_app
    APP_STOPPED=0
  fi

  wait_for_snapshot "$_cmd_snapshot_snap"
  log "Backup complete: $_cmd_snapshot_snap"
  log "This snapshot is local-only and on NO retention clock; delete it when stale:"
  log "  aws ec2 delete-snapshot --region $REGION --snapshot-id $_cmd_snapshot_snap"
  log "To restore it into a volume, see docs/az-move.md."
}

# --- run ---------------------------------------------------------------------

# start_backup_job RESOURCE_ARN LABEL REASON RETENTION -> backup job id.
# --lifecycle is not optional: without it the recovery point never expires.
start_backup_job() {
  _start_backup_job_tags="$(jq -n --arg r "$3" '
    {Project: "gramps-web", Name: "gramps-web-ondemand"}
    + (if $r == "" then {} else {Reason: $r} end)')"
  log "Starting backup job: $2 (retention ${4}d)"
  aws backup start-backup-job --region "$REGION" \
    --backup-vault-name "$VAULT" \
    --resource-arn "$1" \
    --iam-role-arn "$ROLE" \
    --lifecycle "DeleteAfterDays=$4" \
    --recovery-point-tags "$_start_backup_job_tags" \
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
  _cmd_run_reason=""
  [ "$#" -le 1 ] || die "usage: $0 run [reason]"
  _cmd_run_reason="${1:-}"

  _cmd_run_account="$(resolve_account)"
  ROLE="arn:aws:iam::${_cmd_run_account}:role/${BACKUP_ROLE_NAME}"
  readonly ROLE

  VAULT="$(resolve_vault)"
  readonly VAULT

  DEST="$(tf_output_opt backup_copy_vault_arn)"
  readonly DEST

  _cmd_run_lifecycle="$(resolve_plan_retention "$REGION")"
  _cmd_run_retention="$(printf '%s' "$_cmd_run_lifecycle" | cut -f1)"
  _cmd_run_remote_retention="$(printf '%s' "$_cmd_run_lifecycle" | cut -f2)"
  # Belt and braces: a copy destination with no copy_action retention would mean
  # the plan and the stack's mode disagree, and copying without a retention is
  # the one mistake this script exists to prevent.
  [ -z "$DEST" ] || [ "$_cmd_run_remote_retention" != None ] ||
    die "plan '$BACKUP_PLAN_NAME' has no copy_action retention, but the stack
declares a copy destination ($DEST). Apply the '$ENV' stack before running this."

  _cmd_run_primary_label="EBS data volume"
  _cmd_run_primary_arn="$(tf_output ebs_volume_arn)"
  _cmd_run_s3_arn="$(tf_output media_bucket_arn)"

  log "Vault:   $VAULT ($REGION, account $_cmd_run_account)"
  if [ -n "$DEST" ]; then
    log "Copy to: $DEST"
  else
    log "Copy to: (none -- backup.mode is 'local'; this recovery point stays in"
    log "         this account and region)"
  fi
  log "This is CRASH-consistent, like the daily plan. The site stays up."
  log "For an app-consistent point instead, see: $0 snapshot"
  confirm "Take an on-demand recovery point of the $_cmd_run_primary_label and the media bucket?"

  # Both jobs start before either is waited on: the S3 half runs 20-30 min
  # and the primary half a few, so serialising them would add the primary's
  # time for nothing.
  _cmd_run_primary_job="$(start_backup_job "$_cmd_run_primary_arn" "$_cmd_run_primary_label" "$_cmd_run_reason" "$_cmd_run_retention")"
  _cmd_run_s3_job="$(start_backup_job "$_cmd_run_s3_arn" "S3 media bucket" "$_cmd_run_reason" "$_cmd_run_retention")"

  log "Backup jobs started: $_cmd_run_primary_label=$_cmd_run_primary_job S3=$_cmd_run_s3_job"
  log "The S3 job sits at 0% for most of 20-30 min -- AWS Backup's S3 jobs are"
  log "dominated by fixed per-job setup, not by data. That is not a hang."

  poll_job "$_cmd_run_primary_label backup" "$BACKUP_TICKS" "$_cmd_run_primary_job" backup "$REGION"
  poll_job "S3 media bucket backup" "$BACKUP_TICKS" "$_cmd_run_s3_job" backup "$REGION"

  _cmd_run_primary_rp="$(job_recovery_point "$_cmd_run_primary_job")"
  _cmd_run_s3_rp="$(job_recovery_point "$_cmd_run_s3_job")"
  log "Recovery points in $VAULT:"
  log "  $_cmd_run_primary_label: $_cmd_run_primary_rp"
  log "  S3:  $_cmd_run_s3_rp"

  if [ -z "$DEST" ]; then
    log "Done. No copy configured (backup.mode = local)."
    return 0
  fi

  # The copy is this script's job, not the plan's: copy_action fires for
  # plan-driven jobs only, so these recovery points would otherwise expire in
  # the local vault having never gone off-site -- which would make an on-demand
  # backup silently weaker than a scheduled one, in the one way that matters.
  _cmd_run_primary_copy="$(start_copy_job "$_cmd_run_primary_rp" "$_cmd_run_primary_label" "$_cmd_run_remote_retention")"
  _cmd_run_s3_copy="$(start_copy_job "$_cmd_run_s3_rp" "S3 media bucket" "$_cmd_run_remote_retention")"

  log "Copy jobs started: $_cmd_run_primary_label=$_cmd_run_primary_copy S3=$_cmd_run_s3_copy (outbound runs 2-5 min)"
  poll_job "$_cmd_run_primary_label copy" "$COPY_TICKS" "$_cmd_run_primary_copy" copy "$REGION"
  poll_job "S3 media bucket copy" "$COPY_TICKS" "$_cmd_run_s3_copy" copy "$REGION"

  log "Done. Both resources are backed up locally and copied to:"
  log "  $DEST"
  log "Local copies expire in ${_cmd_run_retention}d, remote in ${_cmd_run_remote_retention}d."
  # `status` cannot show the far side: listing another account's vault needs
  # that account's credentials, which is the isolation working as designed.
  log "Confirm the far side from the DESTINATION account's profile:"
  log "  AWS_PROFILE=<backup-admin> aws backup list-recovery-points-by-backup-vault \\"
  log "    --backup-vault-name $(printf '%s' "$DEST" | cut -d: -f7) \\"
  log "    --region $(printf '%s' "$DEST" | cut -d: -f4)"
}

# --- status ------------------------------------------------------------------

cmd_status() {
  [ "$#" -eq 0 ] || die "usage: $0 status"

  _cmd_status_vault="$(resolve_vault)"
  _cmd_status_dest="$(tf_output_opt backup_copy_vault_arn)"

  log "=== Recent backup jobs ($_cmd_status_vault, $REGION) ==="
  aws backup list-backup-jobs --region "$REGION" \
    --by-backup-vault-name "$_cmd_status_vault" --max-results 10 \
    --query 'reverse(sort_by(BackupJobs, &CreationDate))[].[CreationDate,ResourceType,State,PercentDone]' \
    --output table

  if [ -n "$_cmd_status_dest" ]; then
    log "=== Recent copy jobs -> $_cmd_status_dest ==="
    # A copy job stuck in CREATED here is the documented trap: outbound is
    # 2-5 min, but a copy BACK from the backup account runs 4-6 HOURS in
    # CREATED with no status message. Do not read CREATED as broken.
    aws backup list-copy-jobs --region "$REGION" \
      --by-destination-vault-arn "$_cmd_status_dest" --max-results 10 \
      --query 'reverse(sort_by(CopyJobs, &CreationDate))[].[CreationDate,ResourceType,State,StatusMessage]' \
      --output table
  fi

  log "=== Recovery points in $_cmd_status_vault ==="
  aws backup list-recovery-points-by-backup-vault --region "$REGION" \
    --backup-vault-name "$_cmd_status_vault" \
    --query 'reverse(sort_by(RecoveryPoints, &CreationDate))[:10].[CreationDate,ResourceType,Status,RecoveryPointArn]' \
    --output table

  # The one thing here with no retention clock, so the one thing that silently
  # accumulates. Empty is the good state and is stated outright: `--output table`
  # prints NOTHING for an empty list, which reads as a broken command rather
  # than as "you have no stale snapshots".
  log "=== Raw on-demand snapshots from '$0 snapshot' (NO retention clock) ==="
  _cmd_status_snaps="$(aws ec2 describe-snapshots --region "$REGION" --owner-ids self \
    --filters "Name=tag:Name,Values=gramps-data-ondemand" \
    --query 'reverse(sort_by(Snapshots, &StartTime))[].[StartTime,SnapshotId,State,Description]' \
    --output table)"
  if [ -n "$_cmd_status_snaps" ]; then
    echo "$_cmd_status_snaps"
    log "Delete any you no longer want: aws ec2 delete-snapshot --region $REGION --snapshot-id <id>"
  else
    log "(none -- nothing to clean up)"
  fi
}

# --- dispatch ----------------------------------------------------------------

main() {
  require aws terraform jq
  ! wants_usage "$@" || usage
  select_root "$@"
  shift "$ROOT_SHIFT"
  init_root
  [ "$#" -ge 1 ] || usage
  _main_cmd="$1"
  shift
  case "$_main_cmd" in
  snapshot) cmd_snapshot "$@" ;;
  run) cmd_run "$@" ;;
  status) cmd_status "$@" ;;
  *) die "unknown subcommand '$_main_cmd' (expected: snapshot|run|status)" ;;
  esac
}

main "$@"
