#!/bin/sh
# Builds the first-party frontend (build/web) and publishes the CloudFront
# error pages, then invalidates them. This is what
# the gramps-web-frontend CodeBuild project runs; it can also be run locally
# as an escape hatch. Idempotent; safe to re-run.
#
# All inputs arrive as environment variables (the CodeBuild project injects
# them from the module variables); nothing is read from Terraform state.
#   ERRORS_BUCKET_NAME  error-pages S3 bucket (required)
#   DISTRIBUTION_ID     CloudFront distribution to invalidate (required)
#   SITE_TITLE          human-facing site name, baked into the error pages
#                        at build time (npm run build reads it directly --
#                        see src/error/pages.ts); optional, defaults there
#
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

invalidate_cdn() {
  log "invalidating /_errors/* on $DISTRIBUTION_ID ..."
  aws cloudfront create-invalidation \
    --distribution-id "$DISTRIBUTION_ID" --paths "/_errors/*" >/dev/null
}

main() {
  require aws npm
  : "${ERRORS_BUCKET_NAME:?ERRORS_BUCKET_NAME is required}"
  : "${DISTRIBUTION_ID:?DISTRIBUTION_ID is required}"
  build
  publish_errors
  invalidate_cdn
  log "done."
}

main
