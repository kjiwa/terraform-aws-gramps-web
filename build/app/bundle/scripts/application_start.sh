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

readonly PROXY_WAIT_SECONDS="${PROXY_WAIT_SECONDS:-5}"

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

# The proxy service's image and mounts, read from the compose file so that the
# check below runs exactly what compose would. Mounts print as `host:container:mode`,
# with `./` resolved against the compose directory.
proxy_field() {
  awk -v dir="$COMPOSE_DIR" -v field="$1" '
    /^  [a-z_]+:$/ { in_proxy = ($1 == "proxy:"); in_vol = 0; next }
    in_proxy && field == "image" && $1 == "image:" { print $2; exit }
    in_proxy && field == "mounts" && /^    volumes:/ { in_vol = 1; next }
    in_proxy && in_vol && /^      - / {
      sub(/^      - /, "")
      if ($0 ~ /^\.\//) $0 = dir "/" substr($0, 3)
      print
      next
    }
    in_vol && !/^ *#/ { in_vol = 0 }
  ' "$COMPOSE_DIR/docker-compose.yml"
}

# nginx -t on the new config and the freshly rendered maps in a throwaway
# container, before the running proxy is touched: a config nginx rejects then
# fails the deploy while the old proxy keeps serving.
preflight() {
  _preflight_image="$(proxy_field image)"
  [ -n "$_preflight_image" ] || fail_with_proxy_logs "no proxy image in $COMPOSE_DIR/docker-compose.yml"
  set --
  for _preflight_mount in $(proxy_field mounts); do
    set -- "$@" -v "$_preflight_mount"
  done
  log "Checking the proxy configuration with nginx -t..."
  if ! _preflight_out="$(docker run --rm --entrypoint nginx "$@" "$_preflight_image" -t 2>&1)"; then
    log "ERROR: nginx rejects the new configuration; the running proxy is untouched."
    printf '%s\n' "$_preflight_out" | tee -a "${DEPLOY_LOG:-/var/log/gramps-deploy.log}" >&2
    exit 1
  fi
}

# "<id> <status> <restarts>" of the proxy container, or nothing without one.
proxy_state() {
  _proxy_state_id="$(compose ps -q proxy 2>/dev/null || true)"
  [ -n "$_proxy_state_id" ] || return 0
  docker inspect -f '{{.Id}} {{.State.Status}} {{.RestartCount}}' "$_proxy_state_id" 2>/dev/null || true
}

# $1 = proxy_state before `up -d`, $2 = proxy_state now. True when the proxy is
# running and has not restarted since: a proxy that nginx rejects starts, exits
# and restarts. A container compose recreated starts counting from zero, and
# one that was not recreated may carry restarts from before this deploy.
proxy_ok() {
  _proxy_ok_before_id="${1%% *}"
  _proxy_ok_baseline=0
  # shellcheck disable=SC2086 # word-splitting is the point: id, status, restarts
  set -- "$1" $2
  [ "$#" -eq 4 ] || return 1
  [ "$3" = running ] || return 1
  [ "$2" != "$_proxy_ok_before_id" ] || _proxy_ok_baseline="${1##* }"
  [ "$4" -le "$_proxy_ok_baseline" ]
}

# $1 = proxy_state before `up -d`. A proxy that was not recreated is checked
# once; a recreated one is watched for PROXY_WAIT_SECONDS.
await_proxy() {
  _await_proxy_waited=0
  while :; do
    _await_proxy_now="$(proxy_state)"
    proxy_ok "$1" "$_await_proxy_now" || fail_with_proxy_logs "the proxy is not staying up (${_await_proxy_now:-no container})"
    [ "${1%% *}" != "${_await_proxy_now%% *}" ] || return 0
    [ "$_await_proxy_waited" -lt "$PROXY_WAIT_SECONDS" ] || return 0
    sleep 1
    _await_proxy_waited=$((_await_proxy_waited + 1))
  done
}

main() {
  load_instance_env
  case "$PROXY_WAIT_SECONDS" in
  '' | *[!0-9]*)
    log "ERROR: PROXY_WAIT_SECONDS must be a number of seconds, not '$PROXY_WAIT_SECONDS'"
    exit 1
    ;;
  esac
  preflight
  _main_before="$(proxy_state)"
  log "Starting stack..."
  compose up -d --remove-orphans
  await_proxy "$_main_before"
  # `up -d` leaves a running proxy alone when only its mounted files changed
  # (the origin secret maps, the certificate); a reload picks them up. nginx -s
  # reload exits 0 on a config it rejects, so test it first.
  compose exec -T proxy nginx -t || fail_with_proxy_logs "the running proxy rejects its configuration"
  compose exec -T proxy nginx -s reload || fail_with_proxy_logs "nginx reload failed"
}

main "$@"
