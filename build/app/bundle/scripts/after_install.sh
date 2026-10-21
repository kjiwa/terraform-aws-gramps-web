#!/bin/sh
# AfterInstall: assemble the compose env files -- .env (compose-interpolation
# variables only), app.env (non-secret GRAMPSWEB_* config from SSM), and
# secrets.env (GRAMPSWEB_SECRET_KEY / GRAMPSWEB_EMAIL_HOST_PASSWORD, fetched
# individually from SSM) -- and pre-pull the image so ApplicationStart is
# fast. app.env is deliberately not named gramps.env: that name is already
# the bundle's own digest-pinned-image file below ($GRAMPS_ENV).
set -eu

SCRIPT_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
BUNDLE_ROOT="$(dirname -- "$SCRIPT_DIR")"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

readonly GRAMPS_ENV="$BUNDLE_ROOT/gramps.env"

ssm_value() {
  aws ssm get-parameter \
    --name "$1" \
    --with-decryption \
    --query 'Parameter.Value' \
    --output text \
    --region "$REGION"
}

# The image reference the pipeline pinned by digest, from the revision bundle.
image_ref() {
  if [ ! -f "$GRAMPS_ENV" ]; then
    log "ERROR: $GRAMPS_ENV missing from revision"
    exit 1
  fi
  # GRAMPS_IMAGE=<registry>/<repo>@sha256:...
  # shellcheck disable=SC1090
  . "$GRAMPS_ENV"
  : "${GRAMPS_IMAGE:?GRAMPS_IMAGE missing from $GRAMPS_ENV}"
  echo "$GRAMPS_IMAGE"
}

# $1 = image reference. umask 077 covers everything this script writes from
# here on, not just secrets.env below -- it also applies to app.env and
# config.js, written later in this function and by render_frontend_config.
write_env_file() {
  local flask_secret smtp_password
  mkdir -p "$COMPOSE_DIR"
  umask 077

  # Compose-interpolation variables only -- not container env at all, so they
  # stay out of app.env/secrets.env, which docker compose loads via
  # env_file: straight into the containers.
  log "Rendering $COMPOSE_DIR/.env..."
  {
    printf 'GRAMPS_IMAGE=%s\n' "$1"
    printf 'REGION=%s\n' "$REGION"
    printf 'GRAMPS_DATA_ROOT=%s\n' "$GRAMPS_DATA_ROOT"
    printf 'CELERY_REGION=%s\n' "$CELERY_REGION"
  } >"$COMPOSE_DIR/.env"

  # Non-secret GRAMPSWEB_* config, authored as ready-to-use KEY=value lines in
  # SSM (terraform/modules/compute/ssm.tf's gramps_env parameter, named by
  # $SSM_RUNTIME_PARAM in instance.env). Fetched verbatim, no parsing on this
  # end.
  log "Rendering $COMPOSE_DIR/app.env..."
  ssm_value "$SSM_RUNTIME_PARAM" >"$COMPOSE_DIR/app.env"

  # The two secrets, fetched individually as SecureStrings and written
  # directly under upstream's own names -- never stored in a plain SSM String
  # or in git.
  log "Rendering $COMPOSE_DIR/secrets.env..."
  flask_secret="$(ssm_value "$SSM_FLASK_SECRET_PARAM")"
  smtp_password="$(ssm_value "$SSM_SMTP_PASSWORD_PARAM")"
  {
    printf 'GRAMPSWEB_SECRET_KEY=%s\n' "$flask_secret"
    printf 'GRAMPSWEB_EMAIL_HOST_PASSWORD=%s\n' "$smtp_password"
  } >"$COMPOSE_DIR/secrets.env"
}

# Authenticate to ECR when the image lives in an ECR registry; a no-op for any
# other registry (e.g. a GHCR fallback), which pulls anonymously. The registry
# host is everything before the first '/' in the image reference.
ecr_login() {
  local registry
  registry=${1%%/*}
  case "$registry" in
  *.dkr.ecr.*.amazonaws.com)
    log "Authenticating to ECR registry ${registry}..."
    aws ecr get-login-password --region "$REGION" |
      docker login --username AWS --password-stdin "$registry"
    ;;
  esac
}

pull_image() {
  log "Pulling image $1..."
  ecr_login "$1"
  docker pull "$1"
}

# Frontend runtime config, mounted over /app/static/config.js by the compose
# file. Terraform authors the complete file content (the whole
# window.grampsjsConfig object, via jsonencode) and stores it in the
# frontend-config parameter, so this is a verbatim fetch -- no parsing, no
# escaping, no validation of individual keys on this end.
render_frontend_config() {
  log "Rendering $COMPOSE_DIR/config.js..."
  ssm_value "$SSM_FRONTEND_CONFIG_PARAM" >"$COMPOSE_DIR/config.js"
}

# Gramps keeps database.txt/name.txt in the tree's metadata directory. The tree
# id comes from $COMPOSE_DIR/app.env's GRAMPSWEB_TREE_ID (empty when
# api.tree_id is unset: a no-op). Created once only: an existing tree's
# name.txt holds its display name, and rewriting it on every deploy would
# rename the tree of anyone following api.tree_id's own documented advice to
# point at an existing directory.
bootstrap_tree_metadata() {
  local tree_id tree_dir
  tree_id="$(sed -n 's/^GRAMPSWEB_TREE_ID="\(.*\)"$/\1/p' "$COMPOSE_DIR/app.env")"
  [ -n "$tree_id" ] || return 0
  tree_dir="$GRAMPS_DATA_ROOT/db/$tree_id"
  [ -d "$tree_dir" ] && return 0
  log "Bootstrapping sqlite tree metadata at $tree_dir..."
  mkdir -p "$tree_dir"
  printf '%s' "$tree_id" >"$tree_dir/name.txt"
  printf 'sqlite' >"$tree_dir/database.txt"
}

main() {
  local image
  load_instance_env
  image="$(image_ref)"
  write_env_file "$image"
  bootstrap_tree_metadata
  render_frontend_config
  pull_image "$image"
}

main "$@"
