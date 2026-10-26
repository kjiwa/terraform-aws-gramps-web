#!/bin/sh
# ValidateService: confirm gunicorn is serving TLS on :443. Deliberately gates on
# the web port only, NOT the LLM path: it reaches Bedrock over the network
# and would make an otherwise-healthy deploy look failed on a transient error.
# curl -k: the certificate names origin.<domain>, not localhost.
set -eu

SCRIPT_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

readonly URL="https://localhost/"
readonly TIMEOUT=240

# Busts the CloudFront cache for the app's own non-hashed static assets
# (global.css, fonts/*, images/*, webawesome-styles/*, manifest.json) so a
# Gramps Web version bump that changes their content without changing their
# filename doesn't keep serving a stale copy for up to a day (see the
# static-asset cache behaviors in modules/edge/cloudfront_primary.tf).
# Deliberately NOT /*.js: the SPA bundle is content-hashed and self-busts, so
# invalidating it would just spend quota for nothing.
#
# CLOUDFRONT_DISTRIBUTION_ID_PARAM (instance.env) names an SSM parameter
# rather than carrying the distribution ID directly -- the compute module
# that renders instance.env cannot reference modules/edge's output without
# creating a Terraform dependency cycle (edge already depends on compute for
# the origin EIP), so edge publishes the ID to SSM instead and this resolves
# it at deploy time. Any failure here -- a missing/old instance.env, a
# throttled SSM read, a failed invalidation -- is logged and swallowed: the
# deployment has already passed its health check by the time this runs, and
# failing ValidateService over a CDN cache quirk would be a worse outcome
# than a day of stale static assets.
invalidate_cache() {
  _invalidate_cache_distribution_id=""
  if [ -z "${CLOUDFRONT_DISTRIBUTION_ID_PARAM:-}" ]; then
    log "CLOUDFRONT_DISTRIBUTION_ID_PARAM not in $INSTANCE_ENV; skipping cache invalidation."
    return 0
  fi
  if ! _invalidate_cache_distribution_id="$(aws ssm get-parameter \
    --name "$CLOUDFRONT_DISTRIBUTION_ID_PARAM" \
    --query 'Parameter.Value' --output text \
    --region "$REGION" 2>&1)"; then
    log "Could not read $CLOUDFRONT_DISTRIBUTION_ID_PARAM ($_invalidate_cache_distribution_id); skipping cache invalidation."
    return 0
  fi
  log "Invalidating CloudFront cache ($_invalidate_cache_distribution_id) for static assets..."
  if ! aws cloudfront create-invalidation \
    --distribution-id "$_invalidate_cache_distribution_id" \
    --paths '/global.css' '/fonts/*' '/images/*' '/webawesome-styles/*' '/manifest.json' \
    >/dev/null; then
    log "CloudFront invalidation failed; stale static assets may persist briefly."
  fi
}

main() {
  _main_code=""
  load_instance_env
  log "Validating $URL (up to ${TIMEOUT}s)..."
  # Wall-clock deadline, not a sleep count: each failing curl can add up to
  # 5s on top of the sleep, and overshooting the appspec hook timeout (300s)
  # gets the script killed before it can report and dump `compose ps`.
  _main_deadline=$(($(date +%s) + TIMEOUT))
  while [ "$(date +%s)" -lt "$_main_deadline" ]; do
    _main_code="$(curl -o /dev/null -s -w '%{http_code}' --max-time 5 -k "$URL" || echo 000)"
    case "$_main_code" in
    2[0-9][0-9] | 3[0-9][0-9])
      log "Healthy (HTTP $_main_code)."
      invalidate_cache
      return 0
      ;;
    esac
    sleep 5
  done
  log "ERROR: no healthy response from $URL within ${TIMEOUT}s"
  docker compose --env-file "$COMPOSE_DIR/.env" -f "$COMPOSE_DIR/docker-compose.yml" ps >&2 || true
  return 1
}

main "$@"
