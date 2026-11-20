#!/bin/sh
# ApplicationStart: bring the stack up. `up -d` recreates only the containers
# whose image/config changed, so a version bump rolls grampsweb + celery while
# valkey stays put.
set -eu

SCRIPT_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

main() {
  load_instance_env
  log "Starting stack..."
  docker compose \
    --env-file "$COMPOSE_DIR/.env" \
    -f "$COMPOSE_DIR/docker-compose.yml" \
    up -d --remove-orphans
  # `up -d` leaves a running proxy alone when only its mounted files changed
  # (the origin secret maps, the certificate); a reload picks them up.
  docker compose \
    --env-file "$COMPOSE_DIR/.env" \
    -f "$COMPOSE_DIR/docker-compose.yml" \
    exec -T proxy nginx -s reload
}

main "$@"
