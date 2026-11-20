#!/bin/sh
# ValidateService: confirm the app answers through the proxy and the proxy's
# origin secret policy holds on :443. The app is read on the loopback-only
# listener (nginx.conf), because the public listener may answer 403 without the
# origin secret; the public listener is then probed with and without the
# header (check_origin_secret).
# Deliberately gates on the web path only, NOT the LLM path: it reaches Bedrock
# over the network and would make an otherwise-healthy deploy look failed on a
# transient error.
# curl -k: the certificate names origin.<domain>, not localhost.
set -eu

SCRIPT_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

readonly URL="http://localhost/"
readonly TLS_URL="https://localhost/"
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

# The public listener answers on 443 with the proxy's rendered origin secret
# policy. $1 = what the first request, without the header, must get.
# Enforcing: exactly 403 without the header, anything else with the current
# secret. Logging: never 403. A status of 000 means no TLS handshake.
check_origin_secret() {
  _check_origin_secret_map="$COMPOSE_DIR/origin-secret.map"
  [ -f "$_check_origin_secret_map" ] && [ -f "$COMPOSE_DIR/origin-enforce.map" ] || return 1
  _check_origin_secret_value="$(sed -n 's/^"\(.*\)" 1;$/\1/p' "$_check_origin_secret_map" | head -n 1)"
  _check_origin_secret_bare="$(curl -o /dev/null -s -w '%{http_code}' --max-time 5 -k "$TLS_URL" || echo 000)"
  _check_origin_secret_sent="$(curl -o /dev/null -s -w '%{http_code}' --max-time 5 -k \
    -H "X-Origin-Verify: $_check_origin_secret_value" "$TLS_URL" || echo 000)"
  [ "$_check_origin_secret_bare" != 000 ] && [ "$_check_origin_secret_sent" != 000 ] || return 1
  if grep -q '^default 1;$' "$COMPOSE_DIR/origin-enforce.map"; then
    [ "$_check_origin_secret_bare" = 403 ] && [ "$_check_origin_secret_sent" != 403 ]
  else
    [ "$_check_origin_secret_bare" != 403 ] && [ "$_check_origin_secret_sent" != 403 ]
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
      if check_origin_secret; then
        log "Healthy (HTTP $_main_code, origin secret policy holds)."
        invalidate_cache
        prune_images
        return 0
      fi
      ;;
    esac
    sleep 5
  done
  log "ERROR: no healthy response from $URL and $TLS_URL within ${TIMEOUT}s"
  docker compose --env-file "$COMPOSE_DIR/.env" -f "$COMPOSE_DIR/docker-compose.yml" ps >&2 || true
  return 1
}

main "$@"
