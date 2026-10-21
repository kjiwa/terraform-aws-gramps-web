#!/bin/sh
# Single entry point for deployments. Triggers the AWS-side build/deploy for a
# component and waits for it. Reads nothing from Terraform state: the version
# lives in tfvars (baked into the build projects at apply time), and the
# resource names below are repo constants that match terraform/.
#
#   ./deploy.sh gramps   Run the gramps-web CodePipeline (build the image from
#                        source + addons, push to ECR, roll the fleet via
#                        CodeDeploy). To change the version: edit
#                        gramps_web_version in terraform.tfvars, `terraform
#                        apply`, then run this.
#
#   ./deploy.sh web      Run the gramps-web-frontend CodeBuild (build/web:
#                        the error pages and the status page shell, publish to
#                        S3, invalidate CloudFront).
#
# Env:    ENV=<env> selects terraform/config/stack/<env> (default prod). Resource
#         names are per-account constants, so the env only picks which tfvars
#         supplies the region; AWS_PROFILE picks the account.
# Region: $AWS_REGION if set, else primary_region from the env's tfvars.
# Needs: aws.
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
REPO_ROOT="$(dirname -- "$SCRIPT_DIR")"
readonly REPO_ROOT
readonly LOG_PREFIX="deploy"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

env_paths
REGION="$(resolve_region "$TFVARS")"
readonly REGION

# Captures stderr from the polling calls, which must be inspected (not just
# printed) to tell a transient error from a real one. One file, one trap: the
# watch functions run one at a time.
ERR="$(mktemp)"
readonly ERR
trap 'rm -f "$ERR"' EXIT

# --- gramps: CodePipeline ----------------------------------------------------

start_pipeline() {
  aws codepipeline start-pipeline-execution \
    --name "$PIPELINE_NAME" --region "$REGION" \
    --query 'pipelineExecutionId' --output text
}

# $1 = execution id. Returns when it succeeds; dies on any terminal status.
watch_pipeline() {
  local execution_id waited status
  execution_id="$1"
  waited=0
  while :; do
    if status="$(aws codepipeline get-pipeline-execution \
      --pipeline-name "$PIPELINE_NAME" \
      --pipeline-execution-id "$execution_id" \
      --region "$REGION" \
      --query 'pipelineExecution.status' --output text 2>"$ERR")"; then
      case "$status" in
      Succeeded)
        log "pipeline execution $execution_id succeeded."
        return 0
        ;;
      Failed | Cancelled | Superseded | Stopped | Stopping)
        die "pipeline execution $execution_id ended: $status (see the CodePipeline console)"
        ;;
      esac
    elif grep -q PipelineExecutionNotFoundException "$ERR" &&
      [ "$waited" -lt "$NOT_FOUND_GRACE_SECONDS" ]; then
      : # Read replica hasn't caught up to the start yet; keep polling.
    else
      die "get-pipeline-execution failed after ${waited}s: $(cat "$ERR")"
    fi
    sleep "$POLL_SECONDS"
    waited=$((waited + POLL_SECONDS))
  done
}

# Resolves every SSM parameter the CodeDeploy bundle's before_install.sh
# checks again on the instance (build/app/bundle/scripts/before_install.sh's
# preflight_ssm), so a bad parameter name fails here in seconds at the
# operator's terminal instead of after a multi-minute replacement storm on a
# live instance.
preflight_ssm() {
  local invalid
  invalid="$(aws ssm get-parameters --with-decryption \
    --names \
    "/gramps-web/$ENV/gramps-env" \
    "/gramps-web/$ENV/flask-secret" \
    "/gramps-web/$ENV/smtp-password" \
    "/gramps-web/$ENV/frontend-config" \
    --region "$REGION" \
    --query 'InvalidParameters' --output text)"
  [ -z "$invalid" ] || [ "$invalid" = "None" ] ||
    die "SSM parameters missing or undecryptable: $invalid"
}

deploy_gramps() {
  local execution_id
  preflight_ssm
  execution_id="$(start_pipeline)"
  log "pipeline $PIPELINE_NAME started (execution $execution_id). Watching..."
  watch_pipeline "$execution_id"
}

# --- web: CodeBuild ----------------------------------------------------------

# $1 = project name, $2 = hint for the not-found error.
start_codebuild() {
  local project hint build_id
  project="$1"
  hint="$2"
  if ! build_id="$(aws codebuild start-build \
    --project-name "$project" --region "$REGION" \
    --query 'build.id' --output text 2>"$ERR")"; then
    case "$(cat "$ERR")" in
    *ResourceNotFoundException*)
      die "project $project not found in this account/region; $hint"
      ;;
    *) die "start-build failed: $(cat "$ERR")" ;;
    esac
  fi
  echo "$build_id"
}

# $1 = build id, $2 = console URL for the failure message. Returns on success;
# dies on any terminal status.
watch_codebuild() {
  local build_id console phase poll_failures fields status current
  build_id="$1"
  console="$2"
  phase=""
  poll_failures=0
  while :; do
    if ! fields="$(aws codebuild batch-get-builds --ids "$build_id" \
      --region "$REGION" \
      --query 'builds[0].[buildStatus,currentPhase]' --output text 2>"$ERR")"; then
      poll_failures=$((poll_failures + 1))
      [ "$poll_failures" -lt "$MAX_POLL_FAILURES" ] ||
        die "batch-get-builds failed $poll_failures times in a row: $(cat "$ERR")"
      sleep "$POLL_SECONDS"
      continue
    fi
    poll_failures=0
    status="$(printf '%s\n' "$fields" | awk '{print $1}')"
    current="$(printf '%s\n' "$fields" | awk '{print $2}')"
    if [ "$current" != "$phase" ]; then
      phase="$current"
      log "phase: $phase"
    fi
    case "$status" in
    SUCCEEDED)
      log "build $build_id succeeded."
      return 0
      ;;
    FAILED | FAULT | STOPPED | TIMED_OUT)
      die "build $build_id ended: $status (see $console)"
      ;;
    esac
    sleep "$POLL_SECONDS"
  done
}

# $1 = project name, $2 = not-found hint.
run_codebuild() {
  local project hint build_id console
  project="$1"
  hint="$2"
  build_id="$(start_codebuild "$project" "$hint")"
  console="https://$REGION.console.aws.amazon.com/codesuite/codebuild/projects/$project/build/$build_id/?region=$REGION"
  log "build $build_id started. logs: $console"
  watch_codebuild "$build_id" "$console"
}

deploy_web() {
  run_codebuild "$WEB_PROJECT" "has $TFVARS been applied?"
}

main() {
  require aws
  case "${1:-}" in
  gramps) deploy_gramps ;;
  web) deploy_web ;;
  *) die "usage: $0 <gramps|web>" ;;
  esac
  log "done."
}

main "$@"
