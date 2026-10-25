#!/bin/sh
# Single entry point for deployments. Triggers the AWS-side build/deploy for a
# component and waits for it. The region and env come from the root's module
# outputs; the resource names below are repo constants that match the modules.
#
#   ./deploy.sh [--root DIR] gramps
#                        Run the gramps-web CodePipeline (build the image from
#                        source + addons, push to ECR, roll the fleet via
#                        CodeDeploy). To change the version, set
#                        gramps.version on the module, `terraform apply`, then
#                        run this.
#
#   ./deploy.sh [--root DIR] web
#                        Run the gramps-web-frontend CodeBuild (build/web:
#                        the error pages, publish to S3, invalidate
#                        CloudFront).
#
# Root: --root DIR, or $GRAMPS_WEB_ROOT, is the Terraform root that
#       instantiates the module (see common.sh). AWS_PROFILE picks the account.
# Needs: aws, terraform, jq.
set -eu

readonly PIPELINE_NAME="gramps-web"
readonly WEB_PROJECT="gramps-web-frontend"
readonly POLL_SECONDS=5
# GetPipelineExecution is eventually consistent with StartPipelineExecution:
# for a short window after start it can throw
# PipelineExecutionNotFoundException for an execution that exists. Keep
# polling through that error for this long before treating it as real.
readonly NOT_FOUND_GRACE_SECONDS=60
# A transient batch-get-builds error must not kill the watch (the build keeps
# running without us); tolerate a bounded streak before giving up, mirroring
# the not-found grace above.
readonly MAX_POLL_FAILURES=6

SCRIPT_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly SCRIPT_DIR
readonly LOG_PREFIX="deploy"
# shellcheck source=keel/common.sh
. "$SCRIPT_DIR/keel/common.sh"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

# Captures stderr from the polling calls, which must be inspected (not just
# printed) to tell a transient error from a real one. One file, one trap: the
# watch functions run one at a time. Created by main.
ERR=""

# --- gramps: CodePipeline ----------------------------------------------------

start_pipeline() {
  aws codepipeline start-pipeline-execution \
    --name "$PIPELINE_NAME" --region "$REGION" \
    --query 'pipelineExecutionId' --output text
}

# $1 = execution id. Returns when it succeeds; dies on any terminal status.
watch_pipeline() {
  _watch_pipeline_status=""
  _watch_pipeline_execution_id="$1"
  _watch_pipeline_waited=0
  while :; do
    if _watch_pipeline_status="$(aws codepipeline get-pipeline-execution \
      --pipeline-name "$PIPELINE_NAME" \
      --pipeline-execution-id "$_watch_pipeline_execution_id" \
      --region "$REGION" \
      --query 'pipelineExecution.status' --output text 2>"$ERR")"; then
      case "$_watch_pipeline_status" in
      Succeeded)
        log "pipeline execution $_watch_pipeline_execution_id succeeded."
        return 0
        ;;
      Failed | Cancelled | Superseded | Stopped | Stopping)
        die "pipeline execution $_watch_pipeline_execution_id ended: $_watch_pipeline_status (see the CodePipeline console)"
        ;;
      esac
    elif grep -q PipelineExecutionNotFoundException "$ERR" &&
      [ "$_watch_pipeline_waited" -lt "$NOT_FOUND_GRACE_SECONDS" ]; then
      : # Read replica hasn't caught up to the start yet; keep polling.
    else
      die "get-pipeline-execution failed after ${_watch_pipeline_waited}s: $(cat "$ERR")"
    fi
    sleep "$POLL_SECONDS"
    _watch_pipeline_waited=$((_watch_pipeline_waited + POLL_SECONDS))
  done
}

# Resolves every SSM parameter the CodeDeploy bundle's before_install.sh
# checks again on the instance (build/app/bundle/scripts/before_install.sh's
# preflight_ssm), so a bad parameter name fails here in seconds at the
# operator's terminal instead of after a multi-minute replacement storm on a
# live instance.
preflight_ssm() {
  _preflight_ssm_invalid="$(aws ssm get-parameters --with-decryption \
    --names \
    "/gramps-web/$ENV/gramps-env" \
    "/gramps-web/$ENV/flask-secret" \
    "/gramps-web/$ENV/smtp-password" \
    "/gramps-web/$ENV/frontend-config" \
    --region "$REGION" \
    --query 'InvalidParameters' --output text)"
  [ -z "$_preflight_ssm_invalid" ] || [ "$_preflight_ssm_invalid" = "None" ] ||
    die "SSM parameters missing or undecryptable: $_preflight_ssm_invalid"
}

deploy_gramps() {
  preflight_ssm
  _deploy_gramps_execution_id="$(start_pipeline)"
  log "pipeline $PIPELINE_NAME started (execution $_deploy_gramps_execution_id). Watching..."
  watch_pipeline "$_deploy_gramps_execution_id"
}

# --- web: CodeBuild ----------------------------------------------------------

# $1 = project name, $2 = hint for the not-found error.
start_codebuild() {
  _start_codebuild_build_id=""
  _start_codebuild_project="$1"
  _start_codebuild_hint="$2"
  if ! _start_codebuild_build_id="$(aws codebuild start-build \
    --project-name "$_start_codebuild_project" --region "$REGION" \
    --query 'build.id' --output text 2>"$ERR")"; then
    case "$(cat "$ERR")" in
    *ResourceNotFoundException*)
      die "project $_start_codebuild_project not found in this account/region; $_start_codebuild_hint"
      ;;
    *) die "start-build failed: $(cat "$ERR")" ;;
    esac
  fi
  echo "$_start_codebuild_build_id"
}

# $1 = build id, $2 = console URL for the failure message. Returns on success;
# dies on any terminal status.
watch_codebuild() {
  _watch_codebuild_fields="" _watch_codebuild_status="" _watch_codebuild_current=""
  _watch_codebuild_build_id="$1"
  _watch_codebuild_console="$2"
  _watch_codebuild_phase=""
  _watch_codebuild_poll_failures=0
  while :; do
    if ! _watch_codebuild_fields="$(aws codebuild batch-get-builds --ids "$_watch_codebuild_build_id" \
      --region "$REGION" \
      --query 'builds[0].[buildStatus,currentPhase]' --output text 2>"$ERR")"; then
      _watch_codebuild_poll_failures=$((_watch_codebuild_poll_failures + 1))
      [ "$_watch_codebuild_poll_failures" -lt "$MAX_POLL_FAILURES" ] ||
        die "batch-get-builds failed $_watch_codebuild_poll_failures times in a row: $(cat "$ERR")"
      sleep "$POLL_SECONDS"
      continue
    fi
    _watch_codebuild_poll_failures=0
    _watch_codebuild_status="$(printf '%s\n' "$_watch_codebuild_fields" | awk '{print $1}')"
    _watch_codebuild_current="$(printf '%s\n' "$_watch_codebuild_fields" | awk '{print $2}')"
    if [ "$_watch_codebuild_current" != "$_watch_codebuild_phase" ]; then
      _watch_codebuild_phase="$_watch_codebuild_current"
      log "phase: $_watch_codebuild_phase"
    fi
    case "$_watch_codebuild_status" in
    SUCCEEDED)
      log "build $_watch_codebuild_build_id succeeded."
      return 0
      ;;
    FAILED | FAULT | STOPPED | TIMED_OUT)
      die "build $_watch_codebuild_build_id ended: $_watch_codebuild_status (see $_watch_codebuild_console)"
      ;;
    esac
    sleep "$POLL_SECONDS"
  done
}

# $1 = project name, $2 = not-found hint.
run_codebuild() {
  _run_codebuild_project="$1"
  _run_codebuild_hint="$2"
  _run_codebuild_build_id="$(start_codebuild "$_run_codebuild_project" "$_run_codebuild_hint")"
  _run_codebuild_console="https://$REGION.console.aws.amazon.com/codesuite/codebuild/projects/$_run_codebuild_project/build/$_run_codebuild_build_id/?region=$REGION"
  log "build $_run_codebuild_build_id started. logs: $_run_codebuild_console"
  watch_codebuild "$_run_codebuild_build_id" "$_run_codebuild_console"
}

deploy_web() {
  run_codebuild "$WEB_PROJECT" "has the root been applied?"
}

main() {
  require aws terraform jq
  select_root "$@"
  shift "$ROOT_SHIFT"
  init_root
  ERR="$(mktemp "${TMPDIR:-/tmp}/deploy.XXXXXX")"
  readonly ERR
  trap 'rm -f "$ERR"' EXIT
  case "${1:-}" in
  gramps) deploy_gramps ;;
  web) deploy_web ;;
  *) die "usage: $0 [--root DIR] <gramps|web>" ;;
  esac
  log "done."
}

main "$@"
