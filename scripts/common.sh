#!/bin/sh
# Helpers for the operator scripts in this directory. Source keel/common.sh
# first (log, die, require, confirm, aws_as), then this file, then call
# select_root and init_root before anything that reads module outputs.
#
# The operator scripts take the Terraform root that instantiates this module:
# --root DIR as the first argument, or $GRAMPS_WEB_ROOT. They read its outputs
# with `terraform output -json`, so the root must export the module object:
#
#   output "gramps_web" { value = module.gramps_web }
#
# Terraform runs with -chdir=DIR and inherits TF_DATA_DIR and TF_CLI_ARGS_*
# from the environment, so a root with a non-default data dir or required
# variables works by setting those. No `set -eu` here: callers own it.
# shellcheck shell=sh

readonly OUTPUT_NAME="gramps_web"

# select_root ARGS...: sets ROOT_DIR from a leading `--root DIR` or
# $GRAMPS_WEB_ROOT, and ROOT_SHIFT to the arguments consumed (0 or 2).
# shellcheck disable=SC2034 # ROOT_SHIFT is read by the caller
select_root() {
  ROOT_SHIFT=0
  ROOT_DIR="${GRAMPS_WEB_ROOT:-}"
  if [ "${1:-}" = "--root" ]; then
    [ "$#" -ge 2 ] || die "--root needs a directory"
    ROOT_DIR="$2"
    ROOT_SHIFT=2
  fi
  [ -n "$ROOT_DIR" ] ||
    die "no root directory: pass --root DIR or set GRAMPS_WEB_ROOT to the Terraform root that instantiates the module"
  [ -d "$ROOT_DIR" ] || die "root directory not found: $ROOT_DIR"
}

# init_region ARGS...: sets REGION (and ROOT_SHIFT) from $AWS_REGION when it is
# set and no --root is given, else from the root as init_root does. For scripts
# that also run where there is no Terraform root (CodeBuild).
# shellcheck disable=SC2034 # ROOT_SHIFT is read by the caller
init_region() {
  if [ -n "${AWS_REGION:-}" ] && [ "${1:-}" != "--root" ]; then
    ROOT_SHIFT=0
    REGION="$AWS_REGION"
    return 0
  fi
  select_root "$@"
  init_root
}

# Terraform against the selected root.
tf() {
  terraform -chdir="$ROOT_DIR" "$@"
}

# init_root: reads the root's outputs into OUTPUTS_JSON and sets ENV and REGION
# from them.
init_root() {
  require terraform jq
  OUTPUTS_JSON="$(tf output -json)" ||
    die "could not read terraform outputs from $ROOT_DIR (is the root initialized and applied?)"
  ENV="$(tf_output env)"
  REGION="$(tf_output region)"
}

# tf_output_opt NAME -> the module output NAME, or nothing when it is null.
# An output the root does not export at all is an error, not an empty value.
tf_output_opt() {
  printf '%s' "$OUTPUTS_JSON" | jq -e --arg n "$OUTPUT_NAME" --arg k "$1" \
    '.[$n].value | has($k)' >/dev/null 2>&1 ||
    die "output '$1' not found in $ROOT_DIR: the root must export the module as output \"$OUTPUT_NAME\" { value = module.<name> } (applied?)"
  printf '%s' "$OUTPUTS_JSON" | jq -r --arg n "$OUTPUT_NAME" --arg k "$1" \
    '.[$n].value[$k] // empty'
}

# tf_output NAME -> the module output NAME; null is an error.
tf_output() {
  _tf_output_value="$(tf_output_opt "$1")" || exit 1
  [ -n "$_tf_output_value" ] || die "output '$1' is null in $ROOT_DIR"
  printf '%s\n' "$_tf_output_value"
}

# resolve_account -> the caller's account id, checked against the stack's. Catches
# the right-permissions-wrong-account case before it surfaces as an
# AccessDeniedException from whatever AWS call follows.
resolve_account() {
  _resolve_account_got="$(aws sts get-caller-identity --query 'Account' --output text)" ||
    die "could not read caller identity; is AWS_PROFILE set?"
  _resolve_account_want="$(tf_output account_id)"
  [ "$_resolve_account_want" = "$_resolve_account_got" ] ||
    die "wrong account: credentials are for $_resolve_account_got, but the '$ENV' stack is in $_resolve_account_want.
Set AWS_PROFILE to that account's admin profile."
  echo "$_resolve_account_got"
}

# resolve_vault -> the local backup vault name; dies when the stack has none.
resolve_vault() {
  _resolve_vault_name="$(tf_output_opt backup_vault_name)" || exit 1
  [ -n "$_resolve_vault_name" ] ||
    die "no backup vault for '$ENV': backup.mode is 'disabled' (or the stack is not applied)."
  echo "$_resolve_vault_name"
}

# require_backup_mode MODE: dies unless the stack's backup.mode is MODE.
require_backup_mode() {
  _require_backup_mode_have="$(tf_output backup_mode)" || exit 1
  [ "$_require_backup_mode_have" = "$1" ] ||
    die "backup.mode is '$_require_backup_mode_have', not '$1'; this needs a stack with backup.mode = $1."
}

# arn_field ARN N -> the Nth colon-separated field (4 region, 5 account, 7 name
# for a vault ARN).
arn_field() {
  printf '%s' "$1" | cut -d: -f"$2"
}

# dest_vault_name, dest_account_id -> parts of the off-site copy destination
# vault ARN (backup_copy_vault_arn); empty when the stack has no destination.
dest_vault_name() {
  arn_field "$(tf_output_opt backup_copy_vault_arn)" 7
}

dest_account_id() {
  arn_field "$(tf_output_opt backup_copy_vault_arn)" 5
}

# state_address SUFFIX -> the one state address ending in SUFFIX at a module
# boundary, so scripts need not know what the root named the module.
state_address() {
  _state_address_matches="$(tf state list | awk -v s="$1" '
    $0 == s || (length($0) > length(s) && substr($0, length($0) - length(s) + 1) == s &&
      substr($0, length($0) - length(s), 1) == ".")')"
  [ -n "$_state_address_matches" ] || die "no state address ending in $1 in $ROOT_DIR"
  [ "$(printf '%s\n' "$_state_address_matches" | wc -l)" -eq 1 ] ||
    die "more than one state address ends in $1: $_state_address_matches"
  printf '%s\n' "$_state_address_matches"
}

# resolve_plan_retention REGION -> "LOCAL_DAYS\tREMOTE_DAYS", read from the
# live plan, so a recovery point taken outside the schedule expires exactly like
# a nightly one. Rules[0] and CopyActions[0] are safe indexes: backup.tf declares
# exactly one rule with at most one copy_action. Callers set BACKUP_PLAN_NAME
# (repo constant "gramps-web-daily") before use.
resolve_plan_retention() {
  _resolve_plan_retention_region="$1"
  _resolve_plan_retention_id="$(aws backup list-backup-plans --region "$_resolve_plan_retention_region" \
    --query "BackupPlansList[?BackupPlanName=='$BACKUP_PLAN_NAME'].BackupPlanId | [0]" \
    --output text 2>/dev/null || echo None)"
  if [ -z "$_resolve_plan_retention_id" ] || [ "$_resolve_plan_retention_id" = None ]; then
    die "no backup plan '$BACKUP_PLAN_NAME' in $_resolve_plan_retention_region; is the '$ENV' stack applied?"
  fi
  aws backup get-backup-plan --region "$_resolve_plan_retention_region" --backup-plan-id "$_resolve_plan_retention_id" \
    --query 'BackupPlan.Rules[0].[Lifecycle.DeleteAfterDays, CopyActions[0].Lifecycle.DeleteAfterDays]' \
    --output text
}

# --- Remote app control over SSM --------------------------------------------
#
# Shared by backup.sh and azmove.sh (shrink): both stop the app on a live
# instance for an app-consistent operation, then restart it.
# /etc/gramps/instance.env is the boot-glue contract written by user-data and
# consumed by the CodeDeploy hooks; the compose invocation mirrors
# build/app/bundle/scripts/application_start.sh. Only grampsweb and
# grampsweb_celery mount the data volume/tree metadata; valkey keeps running
# (broker state is transient).
readonly REMOTE_ENV=". /etc/gramps/instance.env"
# shellcheck disable=SC2034 # read by callers via ssm_run, not by this file
readonly STOP_CMD="$REMOTE_ENV && docker compose --env-file \"\$COMPOSE_DIR/.env\" -f \"\$COMPOSE_DIR/docker-compose.yml\" stop -t 30 grampsweb_celery grampsweb && sync"
# shellcheck disable=SC2034 # read by callers via ssm_run, not by this file
readonly START_CMD="$REMOTE_ENV && docker compose --env-file \"\$COMPOSE_DIR/.env\" -f \"\$COMPOSE_DIR/docker-compose.yml\" up -d --remove-orphans"

# ssm_run INSTANCE COMMENT CMD: run CMD on INSTANCE via SSM Run Command and
# wait for it. On failure, dump the remote status/stderr and return nonzero.
# $REGION is the global init_root sets, not a parameter.
ssm_run() {
  _ssm_run_instance="$1"
  _ssm_run_comment="$2"
  _ssm_run_cmd="$3"

  _ssm_run_cmd_id="$(aws ssm send-command --region "$REGION" \
    --instance-ids "$_ssm_run_instance" \
    --document-name "AWS-RunShellScript" \
    --comment "$_ssm_run_comment" \
    --parameters "$(jq -n --arg c "$_ssm_run_cmd" '{commands: [$c]}')" \
    --query 'Command.CommandId' --output text)" || return 1

  if ! aws ssm wait command-executed --region "$REGION" \
    --command-id "$_ssm_run_cmd_id" --instance-id "$_ssm_run_instance" 2>/dev/null; then
    log "remote command failed (command id $_ssm_run_cmd_id):"
    aws ssm get-command-invocation --region "$REGION" \
      --command-id "$_ssm_run_cmd_id" --instance-id "$_ssm_run_instance" \
      --query '{status:Status,stderr:StandardErrorContent}' \
      --output text >&2 || true
    return 1
  fi
}

# --- AWS Backup job polling --------------------------------------------------
#
# Shared by backup.sh and restore.sh. KIND is backup|copy|restore -- each
# hides its state in a different place in the describe-*-job response.
# Callers set POLL_SECONDS and HEARTBEAT_EVERY (job-polling cadence) before
# use; PROFILE is optional and only needed when polling a job in another
# account (restore.sh, which juggles two).

job_state() {
  _job_state_id="$1"
  _job_state_kind="$2"
  _job_state_region="$3"
  _job_state_profile="${4:-}"
  case "$_job_state_kind" in
  backup)
    aws_as "$_job_state_profile" backup describe-backup-job --region "$_job_state_region" \
      --backup-job-id "$_job_state_id" --query 'State' --output text 2>/dev/null || echo UNKNOWN
    ;;
  copy)
    aws_as "$_job_state_profile" backup describe-copy-job --region "$_job_state_region" \
      --copy-job-id "$_job_state_id" --query 'CopyJob.State' --output text 2>/dev/null || echo UNKNOWN
    ;;
  restore)
    aws_as "$_job_state_profile" backup describe-restore-job --region "$_job_state_region" \
      --restore-job-id "$_job_state_id" --query 'Status' --output text 2>/dev/null || echo UNKNOWN
    ;;
  esac
}

job_status_message() {
  _job_status_message_id="$1"
  _job_status_message_kind="$2"
  _job_status_message_region="$3"
  _job_status_message_profile="${4:-}"
  case "$_job_status_message_kind" in
  backup)
    aws_as "$_job_status_message_profile" backup describe-backup-job --region "$_job_status_message_region" \
      --backup-job-id "$_job_status_message_id" --query 'StatusMessage' --output text 2>/dev/null || echo "(no status message)"
    ;;
  copy)
    aws_as "$_job_status_message_profile" backup describe-copy-job --region "$_job_status_message_region" \
      --copy-job-id "$_job_status_message_id" --query 'CopyJob.StatusMessage' --output text 2>/dev/null || echo "(no status message)"
    ;;
  restore)
    aws_as "$_job_status_message_profile" backup describe-restore-job --region "$_job_status_message_region" \
      --restore-job-id "$_job_status_message_id" --query 'StatusMessage' --output text 2>/dev/null || echo "(no status message)"
    ;;
  esac
}

job_percent() {
  aws_as "${3:-}" backup describe-backup-job --region "$2" \
    --backup-job-id "$1" --query 'PercentDone' --output text 2>/dev/null || echo "?"
}

# poll_job LABEL TICKS ID KIND REGION [PROFILE]: poll until the job reaches a
# terminal state. Dies on anything but COMPLETED.
poll_job() {
  _poll_job_state="" _poll_job_detail=""
  _poll_job_label="$1"
  _poll_job_ticks="$2"
  _poll_job_id="$3"
  _poll_job_kind="$4"
  _poll_job_region="$5"
  _poll_job_profile="${6:-}"

  _poll_job_i=0
  _poll_job_last=""
  while [ "$_poll_job_i" -lt "$_poll_job_ticks" ]; do
    _poll_job_state="$(job_state "$_poll_job_id" "$_poll_job_kind" "$_poll_job_region" "$_poll_job_profile")"

    case "$_poll_job_state" in
    COMPLETED)
      log "$_poll_job_label: COMPLETED"
      return 0
      ;;
    FAILED | PARTIAL | ABORTED | ABORTING | EXPIRED)
      die "$_poll_job_label: $_poll_job_state -- $(job_status_message "$_poll_job_id" "$_poll_job_kind" "$_poll_job_region" "$_poll_job_profile")"
      ;;
    esac

    if [ "$_poll_job_state" != "$_poll_job_last" ] || [ $((_poll_job_i % HEARTBEAT_EVERY)) -eq 0 ]; then
      _poll_job_detail=""
      [ "$_poll_job_kind" != backup ] || _poll_job_detail=" ($(job_percent "$_poll_job_id" "$_poll_job_region" "$_poll_job_profile")% done)"
      log "$_poll_job_label: $_poll_job_state$_poll_job_detail"
      _poll_job_last="$_poll_job_state"
    fi
    _poll_job_i=$((_poll_job_i + 1))
    sleep "$POLL_SECONDS"
  done
  die "$_poll_job_label: still '$_poll_job_state' after ~$((_poll_job_ticks * POLL_SECONDS / 60)) min; giving up
waiting, but the job may still land."
}

# restore_metadata VAULT RP REGION [AZ] [PROFILE] -> the --metadata JSON for
# start-restore-job: whatever the recovery point declares
# (get-recovery-point-restore-metadata), with availabilityZone patched in when
# AZ is non-empty -- the API returns that field null for an EBS recovery
# point. S3 recovery points have no AZ to patch; the caller patches
# DestinationBucketName into the metadata separately for those, which is why
# this stays generic rather than EBS-specific.
restore_metadata() {
  aws_as "${5:-}" backup get-recovery-point-restore-metadata --region "$3" \
    --backup-vault-name "$1" --recovery-point-arn "$2" --query 'RestoreMetadata' --output json |
    jq -c --arg az "${4:-}" 'if $az != "" then . + {availabilityZone: $az} else . end'
}
