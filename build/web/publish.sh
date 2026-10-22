#!/bin/sh
# Builds the first-party frontend (build/web) and publishes whichever pages
# have a live CloudFront route today, then invalidates them. This is what
# the gramps-web-frontend CodeBuild project runs; it can also be run locally
# as an escape hatch. Idempotent; safe to re-run.
#
# All inputs arrive as environment variables (the CodeBuild project injects
# them from the module variables); nothing is read from Terraform state.
#   ERRORS_BUCKET_NAME  error-pages S3 bucket (required)
#   STATUS_BUCKET_NAME  status page shell's S3 bucket (optional; unset when
#                        status.enabled = false, in which case the publish
#                        and invalidation steps for it are skipped)
#   DISTRIBUTION_ID     CloudFront distribution to invalidate (required)
#   SITE_TITLE          human-facing site name, baked into the error pages
#                        at build time (npm run build reads it directly --
#                        see src/error/pages.ts); optional, defaults there
#
# npm run build always builds both pages (status, error) -- that is what
# proves the whole toolchain on every build, and what CI's `web` job also
# runs. This script only PUBLISHES the ones with a live route: the error
# pages, and the status page shell when STATUS_BUCKET_NAME is set.
# Needs: aws, npm.
set -eu

LOG_PREFIX="build-web"
SCRIPT_DIR=$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)
# build/<component>/<script>, so REPO_ROOT is two levels up.
REPO_ROOT=$(
  unset CDPATH
  cd -- "$SCRIPT_DIR/../.." && pwd
)
readonly LOG_PREFIX SCRIPT_DIR REPO_ROOT

# shellcheck source=../../scripts/keel/common.sh
. "$REPO_ROOT/scripts/keel/common.sh"

build() {
  log "npm ci ..."
  (cd "$SCRIPT_DIR" && npm ci)
  log "npm run build ..."
  (cd "$SCRIPT_DIR" && npm run build)
}

# Short cache-control so an update propagates even before the invalidation
# lands and after a browser has cached the previous version.
publish_errors() {
  log "publishing error pages to s3://$ERRORS_BUCKET_NAME/_errors/ ..."
  aws s3 sync "$SCRIPT_DIR/dist/pages/errors/generated/" "s3://$ERRORS_BUCKET_NAME/_errors/" \
    --cache-control "public, max-age=10" \
    --content-type "text/html; charset=utf-8"
}

# `cp`, not `sync`: this is a single object, so no ListBucket grant is
# needed and there's no chance of touching anything else in the bucket.
publish_status() {
  if [ -z "${STATUS_BUCKET_NAME:-}" ]; then
    log "STATUS_BUCKET_NAME unset, skipping status publish."
    return
  fi
  log "publishing status page shell to s3://$STATUS_BUCKET_NAME/_status/index.html ..."
  aws s3 cp "$SCRIPT_DIR/dist/pages/status.html" "s3://$STATUS_BUCKET_NAME/_status/index.html" \
    --cache-control "public, max-age=60" \
    --content-type "text/html; charset=utf-8"
}

invalidate_cdn() {
  _invalidate_cdn_paths="/_errors/*"
  if [ -n "${STATUS_BUCKET_NAME:-}" ]; then
    _invalidate_cdn_paths="$_invalidate_cdn_paths /_status /_status/"
  fi
  log "invalidating $_invalidate_cdn_paths on $DISTRIBUTION_ID ..."
  # shellcheck disable=SC2086 # the paths list is an intentional word-split list
  aws cloudfront create-invalidation \
    --distribution-id "$DISTRIBUTION_ID" --paths $_invalidate_cdn_paths >/dev/null
}

main() {
  require aws npm
  : "${ERRORS_BUCKET_NAME:?ERRORS_BUCKET_NAME is required}"
  : "${DISTRIBUTION_ID:?DISTRIBUTION_ID is required}"
  build
  publish_errors
  publish_status
  invalidate_cdn
  log "done."
}

main
