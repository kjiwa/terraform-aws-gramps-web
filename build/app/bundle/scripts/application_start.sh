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

readonly PROXY_WAIT_SECONDS="${PROXY_WAIT_SECONDS:-8}"

compose() {
  docker compose --env-file "$COMPOSE_DIR/.env" -f "$COMPOSE_DIR/docker-compose.yml" "$@"
}

# $1 = what went wrong. The proxy's last log lines go to the deploy log and to
# stderr, where CodeDeploy shows them: its nginx error is otherwise gone once
# the rollback recreates the container.
fail_with_proxy_logs() {
  log "ERROR: $1; the proxy's last 30 log lines follow."
  compose logs --tail 30 proxy 2>&1 | tee -a "${DEPLOY_LOG:-/var/log/gramps-deploy.log}" >&2 || true
  exit 1
}

# A proxy whose config nginx rejects starts, exits and restarts, and `exec`
# then fails with "is restarting". Watching it for a few seconds turns that
# into one clear failure.
await_proxy() {
  _await_proxy_waited=0
  while [ "$_await_proxy_waited" -lt "$PROXY_WAIT_SECONDS" ]; do
    _await_proxy_state="$(docker inspect -f '{{.State.Status}} {{.RestartCount}}' "$(compose ps -q proxy)" 2>/dev/null || echo "missing 0")"
    [ "$_await_proxy_state" = "running 0" ] || fail_with_proxy_logs "the proxy is not staying up ($_await_proxy_state)"
    sleep 1
    _await_proxy_waited=$((_await_proxy_waited + 1))
  done
}

main() {
  load_instance_env
  log "Starting stack..."
  compose up -d --remove-orphans
  await_proxy
  # `up -d` leaves a running proxy alone when only its mounted files changed
  # (the origin secret maps, the certificate); a reload picks them up.
  compose exec -T proxy nginx -s reload || fail_with_proxy_logs "nginx reload failed"
}

main "$@"
