#!/bin/sh
# Builds the Gramps Web image (upstream release + the configured addons),
# pushes a multi-arch index to ECR, and writes the digest-pinned reference into
# bundle/gramps.env for the CodeDeploy bundle beside it. Runs inside the app
# pipeline's CodeBuild (privileged mode, for docker). Every input arrives as an
# environment variable set by the CodeBuild project from tfvars; nothing is
# read from Terraform state.
#
# Required env:
#   ECR_REPO_URL        <acct>.dkr.ecr.<region>.amazonaws.com/gramps-web
#   GRAMPS_WEB_VERSION  upstream grampsweb tag to build from (e.g. 26.10.2)
#   AWS_DEFAULT_REGION  provided by CodeBuild
# Optional env:
#   ADDONS              space-separated addon directory names from the root of
#                       addons-source; empty builds the plain upstream image
#   ADDONS_SOURCE_REPO  defaults to the gramps-project addons-source repo
#   BASE_IMAGE          defaults to the upstream grampsweb GHCR image
#   GRAMPS_WEB_REPO     gramps-web (frontend) repo whose built dist/ replaces
#                       the upstream frontend; empty ships the upstream
#                       frontend as-is
#   GRAMPS_WEB_REF      git ref to build from GRAMPS_WEB_REPO; required when
#                       the repo is set
set -eu

LOG_PREFIX="build-gramps"
SCRIPT_DIR=$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)
# This component is two levels down; $REPO_ROOT exists only to reach
# scripts/common.sh. Everything this script touches lives in $SCRIPT_DIR, which
# is also the docker build context: the staging dirs must sit beside the
# Dockerfile for its COPYs to see them, and .dockerignore (which whitelists
# exactly those two) is only read from the context root.
REPO_ROOT=$(
  unset CDPATH
  cd -- "$SCRIPT_DIR/../.." && pwd
)
ADDONS="${ADDONS:-}"
ADDONS_SOURCE_REPO="${ADDONS_SOURCE_REPO:-https://github.com/gramps-project/addons-source.git}"
BASE_IMAGE="${BASE_IMAGE:-ghcr.io/gramps-project/grampsweb}"
GRAMPS_WEB_REPO="${GRAMPS_WEB_REPO:-}"
GRAMPS_WEB_REF="${GRAMPS_WEB_REF:-}"
STAGE_DIR="$SCRIPT_DIR/addons-stage"
SOURCE_DIR="$SCRIPT_DIR/.addons-source"
FRONTEND_STAGE_DIR="$SCRIPT_DIR/frontend-stage"
FRONTEND_SOURCE_DIR="$SCRIPT_DIR/.gramps-web-source"
BUNDLE_ENV="$SCRIPT_DIR/bundle/gramps.env"
PLATFORMS="linux/amd64,linux/arm64"
readonly LOG_PREFIX SCRIPT_DIR REPO_ROOT ADDONS ADDONS_SOURCE_REPO \
  BASE_IMAGE GRAMPS_WEB_REPO GRAMPS_WEB_REF STAGE_DIR SOURCE_DIR \
  FRONTEND_STAGE_DIR FRONTEND_SOURCE_DIR BUNDLE_ENV PLATFORMS

# shellcheck source=../../scripts/common.sh
. "$REPO_ROOT/scripts/common.sh"

ecr_login() {
  local registry
  registry=${ECR_REPO_URL%%/*}
  log "authenticating to ECR (${registry})..."
  aws ecr get-login-password --region "$AWS_DEFAULT_REGION" |
    docker login --username AWS --password-stdin "$registry"
}

# The addon branch and the plugin path both key off the base image's Gramps
# major.minor (6.0 -> series 60 -> maintenance/gramps60). Read it straight from
# the image so the mapping is never hand-maintained. --entrypoint bypasses the
# image's gunicorn/celery launcher.
detect_series() {
  local series
  # The || die keeps a docker failure from killing the script via set -e
  # before the diagnostic prints.
  series=$(docker run --rm --entrypoint python3 "$BASE_IMAGE:$GRAMPS_WEB_VERSION" \
    -c 'import gramps.version as v; p=v.VERSION.split("."); print(p[0]+p[1])') ||
    die "could not read Gramps version from $BASE_IMAGE:$GRAMPS_WEB_VERSION"
  [ -n "$series" ] || die "could not read Gramps version from $BASE_IMAGE:$GRAMPS_WEB_VERSION"
  echo "$series"
}

# Clone addons-source at the matching maintenance branch and copy each addon
# named in $ADDONS (space-separated, from gramps_addons in tfvars) into the
# build stage. Gramps loads plugins straight from source (.gpr.py/.py), so no
# make.py packaging or .mo compilation is required. An empty $ADDONS is valid:
# the stage dir is created empty and the image is the plain upstream release.
stage_addons() {
  local branch addon
  branch="maintenance/gramps$SERIES"
  rm -rf "$SOURCE_DIR" "$STAGE_DIR"
  mkdir -p "$STAGE_DIR"

  if [ -z "$ADDONS" ]; then
    log "no addons configured; building the plain upstream image"
    return 0
  fi

  log "cloning addons-source ($branch)..."
  git clone --quiet --depth 1 --branch "$branch" "$ADDONS_SOURCE_REPO" "$SOURCE_DIR"

  # Word splitting is the interface; names are validated ([A-Za-z0-9._-]) by
  # the gramps_addons variable before they reach this env var.
  # shellcheck disable=SC2086
  for addon in $ADDONS; do
    [ -d "$SOURCE_DIR/$addon" ] ||
      die "addon '$addon' not found at root of addons-source $branch"
    log "staging addon: $addon"
    cp -R "$SOURCE_DIR/$addon" "$STAGE_DIR/$addon"
  done

  rm -rf "$SOURCE_DIR"
}

# Optionally replace the upstream frontend: clone GRAMPS_WEB_REPO at
# GRAMPS_WEB_REF, build its dist/ (npm/rollup, same as upstream's release
# workflow), and stage it for the Dockerfile to COPY over /app/static. An
# empty GRAMPS_WEB_REPO is the normal case: the stage dir is created empty and
# the upstream image's frontend ships as-is. The ref is mandatory when the
# repo is set so the deployed frontend is never ambiguous; pin a SHA for
# reproducible builds. The API under the frontend stays the one pinned inside
# BASE_IMAGE:GRAMPS_WEB_VERSION, so base the ref on that release's frontend
# (e.g. the v<version> tag), not on a main that may want newer endpoints.
stage_frontend() {
  rm -rf "$FRONTEND_SOURCE_DIR" "$FRONTEND_STAGE_DIR"
  mkdir -p "$FRONTEND_STAGE_DIR"

  if [ -z "$GRAMPS_WEB_REPO" ]; then
    log "no frontend override; shipping the upstream frontend"
    return 0
  fi
  [ -n "$GRAMPS_WEB_REF" ] ||
    die "GRAMPS_WEB_REF is required when GRAMPS_WEB_REPO is set"
  require node npm

  log "building frontend override: $GRAMPS_WEB_REPO @ $GRAMPS_WEB_REF"
  git clone --quiet "$GRAMPS_WEB_REPO" "$FRONTEND_SOURCE_DIR"
  git -C "$FRONTEND_SOURCE_DIR" checkout --quiet "$GRAMPS_WEB_REF"
  (cd "$FRONTEND_SOURCE_DIR" && npm ci && npm run build)
  [ -f "$FRONTEND_SOURCE_DIR/dist/index.html" ] ||
    die "frontend build produced no dist/index.html"
  cp -R "$FRONTEND_SOURCE_DIR/dist/." "$FRONTEND_STAGE_DIR/"
  rm -rf "$FRONTEND_SOURCE_DIR"
}

build_and_push() {
  local tag
  tag="$ECR_REPO_URL:$GRAMPS_WEB_VERSION"
  log "building $tag for $PLATFORMS..."
  # Reuse the builder when it exists; create it (loudly) when it does not.
  # The other order swallows the create error and re-fails with a misleading
  # "no builder" message from use.
  docker buildx use gramps-builder 2>/dev/null ||
    docker buildx create --use --name gramps-builder >/dev/null
  docker buildx build \
    --platform "$PLATFORMS" \
    --build-arg "BASE_IMAGE=$BASE_IMAGE" \
    --build-arg "GRAMPS_WEB_VERSION=$GRAMPS_WEB_VERSION" \
    --build-arg "GRAMPS_SERIES=$SERIES" \
    --tag "$tag" \
    --push \
    "$SCRIPT_DIR"
}

# Resolve the manifest-list (index) digest of what we just pushed and pin it in
# the bundle. The index digest is arch-agnostic; the instance's docker selects
# the right per-arch manifest at pull time.
write_bundle_env() {
  local repo digest
  # Strip the registry host only: ECR repo names may themselves contain '/'.
  repo=${ECR_REPO_URL#*/}
  digest=$(aws ecr describe-images \
    --repository-name "$repo" \
    --image-ids "imageTag=$GRAMPS_WEB_VERSION" \
    --region "$AWS_DEFAULT_REGION" \
    --query 'imageDetails[0].imageDigest' --output text)
  if [ -z "$digest" ] || [ "$digest" = "None" ]; then
    die "could not resolve pushed image digest for tag $GRAMPS_WEB_VERSION"
  fi
  printf 'GRAMPS_IMAGE=%s@%s\n' "$ECR_REPO_URL" "$digest" >"$BUNDLE_ENV"
  log "pinned image: $ECR_REPO_URL@$digest"
}

main() {
  : "${ECR_REPO_URL:?ECR_REPO_URL is required}"
  : "${GRAMPS_WEB_VERSION:?GRAMPS_WEB_VERSION is required}"
  : "${AWS_DEFAULT_REGION:?AWS_DEFAULT_REGION is required}"
  require aws docker git

  SERIES=$(detect_series)
  readonly SERIES
  log "Gramps series: $SERIES (branch maintenance/gramps$SERIES)"

  ecr_login
  stage_addons
  stage_frontend
  build_and_push
  write_bundle_env
  log "done."
}

main "$@"
