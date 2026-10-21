#!/bin/sh
# Shared helpers for the operator CLI scripts in this directory (deploy.sh,
# azmove.sh, backup.sh, restore.sh, clean-amis.sh, tf.sh) and the CodeBuild
# build scripts under build/<component>/. Sourcing scripts set LOG_PREFIX
# before sourcing and call env_paths (or config_paths) before tf/tf_output.
#
# The build scripts live two levels down, so they set REPO_ROOT from
# "$SCRIPT_DIR/../.." and source this by its full path. The rule there:
# $SCRIPT_DIR addresses anything inside the component; $REPO_ROOT exists only to
# reach this file (and, for build/ami, terraform/config/stack/$ENV).
# FORCE=1 makes confirm non-interactive. No `set -eu` here: every caller sets
# it before sourcing, and the setting is the caller's to own.
# shellcheck shell=sh

log() { echo "[${LOG_PREFIX:-script}] $*" >&2; }

die() {
  echo "[${LOG_PREFIX:-script}] ERROR: $*" >&2
  exit 1
}

# $1 = prompt. FORCE=1 skips (non-interactive).
confirm() {
  local reply
  [ "${FORCE:-0}" = "1" ] && return 0
  printf '[%s] %s\n[%s] type "yes" to continue: ' \
    "${LOG_PREFIX:-script}" "$1" "${LOG_PREFIX:-script}" >&2
  read -r reply
  [ "$reply" = "yes" ] || die "aborted by user"
}

require() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
  done
}

# Print the caller's header comment as its usage text: line 2 to the first
# non-comment line, so it tracks header edits instead of a line range. $0 is the
# sourcing script, not this file. Scripts whose header is not usage text (or
# that want a one-liner) define their own after sourcing.
usage() {
  awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0" >&2
  exit 2
}

# Deployment region for the AWS CLI: $AWS_REGION wins; otherwise primary_region
# parsed out of the tfvars config file ($1); otherwise us-east-1. Keeps the
# scripts pointed at the same region as the Terraform stack without reading
# Terraform state.
resolve_region() {
  local region
  if [ -n "${AWS_REGION:-}" ]; then
    echo "$AWS_REGION"
    return 0
  fi
  region="$(sed -n \
    's/^[[:space:]]*primary_region[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$1" 2>/dev/null | head -n 1)"
  echo "${region:-us-east-1}"
}

# Instance selection. Each root under terraform/roots is applied once per
# instance, and terraform/config/<root>/<instance> holds that instance's config
# (terraform.tfvars), state location (backend.hcl), and .terraform data dir.
# $1 is the path under terraform/config: "<root>/<instance>", or a bare
# "<instance>" meaning "stack/<instance>" (the common case). The root segment is
# not decoration: a backup account is an instance of both bootstrap and
# backup-account, so a bare name cannot be resolved. Callers set REPO_ROOT first.
config_paths() {
  case "$1" in
  */*)
    ROOT="${1%%/*}"
    INSTANCE="${1#*/}"
    ;;
  *)
    ROOT="stack"
    INSTANCE="$1"
    ;;
  esac
  ROOT_DIR="$REPO_ROOT/terraform/roots/$ROOT"
  CONFIG_DIR="$REPO_ROOT/terraform/config/$ROOT/$INSTANCE"
  TFVARS="$CONFIG_DIR/terraform.tfvars"
  [ -d "$ROOT_DIR" ] || die "no root '$ROOT' (see terraform/roots/)"
  [ -f "$TFVARS" ] ||
    die "no config '$ROOT/$INSTANCE': $TFVARS not found (see terraform/config/$ROOT/)"
  readonly ROOT INSTANCE ROOT_DIR CONFIG_DIR TFVARS
}

# Environment selection for the stack root, which is what every script other
# than tf.sh works with. ENV defaults to prod.
env_paths() {
  ENV="${ENV:-prod}"
  config_paths "stack/$ENV"
  readonly ENV
}

# Terraform against the selected root, with that instance's data dir (state and
# backend binding). The per-instance TF_DATA_DIR is what makes switching
# instances safe without -reconfigure: the binding lives with the config rather
# than in one shared dir that silently outlives the last init. Callers add
# -var-file="$TFVARS" on subcommands that evaluate the configuration
# (plan/apply/import/...); state and output subcommands need only the data dir.
# scripts/tf.sh is the interactive wrapper over this.
tf() {
  TF_DATA_DIR="$CONFIG_DIR/.terraform" terraform -chdir="$ROOT_DIR" "$@"
}

tf_output() {
  tf output -raw "$1" 2>/dev/null ||
    die "could not read terraform output '$1' (is the '$ENV' stack applied?)"
}

# Like tf_output, but a null/absent output is not fatal: prints nothing.
# Needed because backup_vault_name/backup_copy_vault_arn are null in
# local/disabled mode, and `terraform output -raw` treats null as an error
# rather than an empty string.
tf_output_opt() {
  tf output -raw "$1" 2>/dev/null || true
}

# aws_as PROFILE ARGS...: run `aws ARGS...`, with AWS_PROFILE overridden to
# PROFILE when non-empty (the caller's own profile is left alone otherwise).
# This repo has no assume_role anywhere -- talking to a second AWS account
# always means a second profile, and this is the one place scripts touch
# AWS_PROFILE to do it.
aws_as() {
  local profile
  profile="$1"
  shift
  if [ -n "$profile" ]; then
    AWS_PROFILE="$profile" aws "$@"
  else
    aws "$@"
  fi
}

# --- tfvars resolution for values with no Terraform output ------------------
#
# The stack root exposes some outputs (ebs_volume_id, backup_vault_name, ...)
# but not everything a script needs -- an EC2/Backup resource ARN is fully
# determined by service + region + account + resource name, so scripts
# reconstruct it from tfvars rather than adding an output just to read it
# back. Used by backup.sh and restore.sh.

# -> the caller's account id, checked against tfvars' account_id. Catches the
# right-permissions-wrong-account case early, before it surfaces confusingly
# as an AccessDeniedException from whatever AWS Backup call follows (this
# can't decrypt state itself, unlike tf_output, so it also catches the
# ReadOnly-profile case before that call does).
resolve_account() {
  local want got
  got="$(aws sts get-caller-identity --query 'Account' --output text)" ||
    die "could not read caller identity; is AWS_PROFILE set?"
  # Anchored at column 0, and that is load-bearing rather than tidiness: the
  # tfvars carries account_id TWICE -- the workload account at the top level,
  # and the backup account nested inside the `backup` block. Only the top-level
  # one is unindented. Allowing leading whitespace here would match both and
  # leave the winner down to line order, so a reordered tfvars would have this
  # guard reject the correct profile for being the wrong account.
  want="$(sed -n \
    's/^account_id[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$TFVARS" 2>/dev/null | head -n 1)"
  [ -z "$want" ] || [ "$want" = "$got" ] ||
    die "wrong account: credentials are for $got, but $TFVARS declares $want.
Set AWS_PROFILE to the $ENV workload account's ADMIN profile."
  echo "$got"
}

# volume_arn REGION VOLUME_ID -> its ARN. EC2 volume ARNs are fully
# determined by region + account + id (describe-volumes does not return one
# directly).
volume_arn() {
  printf 'arn:aws:ec2:%s:%s:volume/%s\n' "$1" "$(resolve_account)" "$2"
}

# tfvars_block_field BLOCK NAME DEFAULT -> the value of NAME inside the
# top-level `BLOCK = { ... }` object in tfvars, or DEFAULT if absent.
# Handles both this repo's usual one-field-per-line style AND a single-line
# object literal (`BLOCK = { a = "x", b = "y" }`) -- both are valid HCL, and
# a tfvars file is free to use either per block, so the parser must not
# silently prefer one: a single-line block that isn't matched falls through
# to DEFAULT with no error at all.
tfvars_block_field() {
  local block="$1" name="$2" default="$3" val
  val="$(awk -v block="$block" '
    $0 ~ "^" block "[[:space:]]*=[[:space:]]*\\{" {
      line = $0
      sub("^" block "[[:space:]]*=[[:space:]]*\\{", "", line)
      if (line ~ /\}[[:space:]]*$/) {
        sub(/\}[[:space:]]*$/, "", line)
        n = split(line, parts, ",")
        for (i = 1; i <= n; i++) print parts[i]
        exit
      }
      if (line !~ /^[[:space:]]*$/) print line
      f = 1
      next
    }
    f && /^\}/ { exit }
    f { print }
  ' "$TFVARS" 2>/dev/null |
    sed -n "s/^[[:space:]]*${name}[[:space:]]*=[[:space:]]*\"\{0,1\}\([^\",]*\)\"\{0,1\}[[:space:]]*,\{0,1\}[[:space:]]*\$/\1/p" |
    head -n 1)"
  echo "${val:-$default}"
}

# backup_field NAME DEFAULT -> the value of NAME inside the top-level
# `backup = { ... }` object in tfvars, or DEFAULT if absent. Mirrors the
# stack root's optional(...) defaults, since scripts read tfvars directly.
backup_field() {
  tfvars_block_field backup "$1" "$2"
}

# -> the off-site copy destination's region. An explicit backup.region wins;
# otherwise cross_region/cross_account default to us-east-2, and local/
# disabled fall back to primary_region (via resolve_region, whose own
# us-east-1 default matches primary_region's own default). Mirrors
# terraform/roots/stack/locals.tf's backup_region local.
resolve_backup_region() {
  local mode region
  mode="$(backup_field mode local)"
  region="$(backup_field region "")"
  if [ -n "$region" ]; then
    echo "$region"
    return 0
  fi
  case "$mode" in
  cross_region | cross_account) echo "us-east-2" ;;
  *) resolve_region "$TFVARS" ;;
  esac
}

# -> the off-site copy destination vault ARN, or empty when backup.mode is
# local/disabled. Mirrors local.backup_copy_vault_arn in
# terraform/modules/storage/backup.tf: cross_region copies to a vault THAT
# module owns, named by the gramps-web-backup-replica repo constant;
# cross_account copies to a vault the destination account owns, named by
# backup.dest_vault_name (default gramps-web-backup-replica, matching the
# backup account root's own vault_name default -- terraform/roots/backup-account/variables.tf).
# Like volume_arn above, fully determined by region + account + name -- but
# the name match across accounts is a contract enforced only at runtime; a
# mismatch is a failed copy job, not a plan error, because the destination
# vault lives in an account this repo's Terraform cannot see.
resolve_dest_vault_arn() {
  local mode region
  mode="$(backup_field mode local)"
  region="$(resolve_backup_region)"
  case "$mode" in
  cross_region)
    printf 'arn:aws:backup:%s:%s:backup-vault:gramps-web-backup-replica\n' \
      "$region" "$(resolve_account)"
    ;;
  cross_account)
    printf 'arn:aws:backup:%s:%s:backup-vault:%s\n' \
      "$region" "$(backup_field account_id "")" \
      "$(backup_field dest_vault_name gramps-web-backup-replica)"
    ;;
  *) : ;; # local or disabled: no copy destination.
  esac
}

# resolve_plan_retention REGION -> "LOCAL_DAYS\tREMOTE_DAYS", read from the
# LIVE plan rather than tfvars: the goal is "a recovery point taken outside
# the schedule expires exactly like a nightly one," and the plan is the
# honest source of truth for that -- a tfvars value only says what the plan
# WOULD be at the next apply. Rules[0] and CopyActions[0] are safe indexes:
# backup.tf declares exactly one rule with at most one copy_action. Callers
# set BACKUP_PLAN_NAME (repo constant "gramps-web-daily") before use.
resolve_plan_retention() {
  local region id
  region="$1"
  id="$(aws backup list-backup-plans --region "$region" \
    --query "BackupPlansList[?BackupPlanName=='$BACKUP_PLAN_NAME'].BackupPlanId | [0]" \
    --output text 2>/dev/null || echo None)"
  if [ -z "$id" ] || [ "$id" = None ]; then
    die "no backup plan '$BACKUP_PLAN_NAME' in $region; is the '$ENV' stack applied?"
  fi
  aws backup get-backup-plan --region "$region" --backup-plan-id "$id" \
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
# $REGION is the caller's own global (env_paths + resolve_region), not a
# param -- same pattern as TFVARS/ENV/ROOT_DIR elsewhere in this file.
# shellcheck disable=SC2153 # $REGION is the caller's global, not a typo of the local `region` used elsewhere in this file
ssm_run() {
  local instance comment cmd cmd_id
  instance="$1"
  comment="$2"
  cmd="$3"

  cmd_id="$(aws ssm send-command --region "$REGION" \
    --instance-ids "$instance" \
    --document-name "AWS-RunShellScript" \
    --comment "$comment" \
    --parameters "$(jq -n --arg c "$cmd" '{commands: [$c]}')" \
    --query 'Command.CommandId' --output text)" || return 1

  if ! aws ssm wait command-executed --region "$REGION" \
    --command-id "$cmd_id" --instance-id "$instance" 2>/dev/null; then
    log "remote command failed (command id $cmd_id):"
    aws ssm get-command-invocation --region "$REGION" \
      --command-id "$cmd_id" --instance-id "$instance" \
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
  local id kind region profile
  id="$1"
  kind="$2"
  region="$3"
  profile="${4:-}"
  case "$kind" in
  backup)
    aws_as "$profile" backup describe-backup-job --region "$region" \
      --backup-job-id "$id" --query 'State' --output text 2>/dev/null || echo UNKNOWN
    ;;
  copy)
    aws_as "$profile" backup describe-copy-job --region "$region" \
      --copy-job-id "$id" --query 'CopyJob.State' --output text 2>/dev/null || echo UNKNOWN
    ;;
  restore)
    aws_as "$profile" backup describe-restore-job --region "$region" \
      --restore-job-id "$id" --query 'Status' --output text 2>/dev/null || echo UNKNOWN
    ;;
  esac
}

job_status_message() {
  local id kind region profile
  id="$1"
  kind="$2"
  region="$3"
  profile="${4:-}"
  case "$kind" in
  backup)
    aws_as "$profile" backup describe-backup-job --region "$region" \
      --backup-job-id "$id" --query 'StatusMessage' --output text 2>/dev/null || echo "(no status message)"
    ;;
  copy)
    aws_as "$profile" backup describe-copy-job --region "$region" \
      --copy-job-id "$id" --query 'CopyJob.StatusMessage' --output text 2>/dev/null || echo "(no status message)"
    ;;
  restore)
    aws_as "$profile" backup describe-restore-job --region "$region" \
      --restore-job-id "$id" --query 'StatusMessage' --output text 2>/dev/null || echo "(no status message)"
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
  local label ticks id kind region profile i state last detail
  label="$1"
  ticks="$2"
  id="$3"
  kind="$4"
  region="$5"
  profile="${6:-}"

  i=0
  last=""
  while [ "$i" -lt "$ticks" ]; do
    state="$(job_state "$id" "$kind" "$region" "$profile")"

    case "$state" in
    COMPLETED)
      log "$label: COMPLETED"
      return 0
      ;;
    FAILED | PARTIAL | ABORTED | ABORTING | EXPIRED)
      die "$label: $state -- $(job_status_message "$id" "$kind" "$region" "$profile")"
      ;;
    esac

    if [ "$state" != "$last" ] || [ $((i % HEARTBEAT_EVERY)) -eq 0 ]; then
      detail=""
      [ "$kind" != backup ] || detail=" ($(job_percent "$id" "$region" "$profile")% done)"
      log "$label: $state$detail"
      last="$state"
    fi
    i=$((i + 1))
    sleep "$POLL_SECONDS"
  done
  die "$label: still '$state' after ~$((ticks * POLL_SECONDS / 60)) min; giving up
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
