#!/bin/sh
# Cleanly stops the containers that write to the gramps data volume, syncs, and
# detaches the data volume, so the replacement attaches it at once and no
# SQLite write is cut. Two triggers, one drain:
#
#   (no argument)  polls IMDSv2 for the EC2 Spot interruption notice (issued
#                  ~2 min before reclaim) and drains on it, then marks the
#                  instance Unhealthy so the ASG launches the replacement
#                  immediately instead of waiting for the reclaim itself. This
#                  also makes a backup taken near a reclaim trustworthy: the
#                  daily AWS Backup plan and `scripts/backup.sh run` are both
#                  crash-consistent.
#   stop           run by the unit's ExecStop at shutdown. ASG terminations
#                  (instance refresh, scale-in) emit no Spot notice; this
#                  drains them, and only them: an instance whose ASG
#                  lifecycle state is not Terminating (a reboot) is left to
#                  systemd, because a detached volume would never be
#                  reattached and stopped containers do not restart.
#
# The first trigger to start a drain owns it; the other waits for it or does
# nothing. Installed by build/ami/install.sh as /usr/local/bin/gramps-spot-drain,
# run by gramps-spot-drain.service.
set -eu

readonly INSTANCE_ENV="${INSTANCE_ENV:-/etc/gramps/instance.env}"
readonly DRAIN_CLAIM="${DRAIN_CLAIM:-/run/gramps-drain}"
readonly DRAIN_WAIT_SECONDS="${DRAIN_WAIT_SECONDS:-50}"
readonly POLL_SECONDS=5
# Seconds each writer gets to stop. Compose stops celery, then web, in turn: a
# Spot notice leaves ~120 s, the ExecStop budget (TimeoutStopSec=60) leaves
# room for 2 x 20 plus sync and detach. The default 10 would cut long celery
# tasks (exports, reindex) short.
readonly SPOT_GRACE=30
readonly STOP_GRACE=20

log() {
  # stdout lands in the journal via the unit.
  echo "[spot-drain] $*"
}

# shellcheck source=gramps-runtime.sh
. "${GRAMPS_RUNTIME_LIB:-/usr/local/lib/gramps-runtime.sh}"

# The ExecStop process starts with no environment of its own: REGION and the
# rest come from instance.env, before any use of them.
load_env() {
  if [ -f "$INSTANCE_ENV" ]; then
    # shellcheck disable=SC1090
    . "$INSTANCE_ENV"
  fi
}

# $1 = seconds of grace per container.
stop_writers() {
  if [ -n "${COMPOSE_DIR:-}" ]; then
    docker compose --env-file "$COMPOSE_DIR/.env" \
      -f "$COMPOSE_DIR/docker-compose.yml" \
      stop -t "$1" grampsweb_celery grampsweb ||
      log "compose stop failed; syncing anyway"
  else
    log "no COMPOSE_DIR (boot glue incomplete); nothing to stop"
  fi
  sync
  log "Containers stopped."
}

# True when this caller is the first to ask for a drain.
claim_drain() {
  mkdir "$DRAIN_CLAIM" 2>/dev/null
}

finish_drain() {
  touch "$DRAIN_CLAIM/done"
  log "Drain complete."
}

# Another trigger owns the drain: give it up to DRAIN_WAIT_SECONDS to finish.
await_drain() {
  _await_drain_waited=0
  while [ ! -f "$DRAIN_CLAIM/done" ] && [ "$_await_drain_waited" -lt "$DRAIN_WAIT_SECONDS" ]; do
    sleep 1
    _await_drain_waited=$((_await_drain_waited + 1))
  done
}

# Detached and marked unhealthy only after the containers stopped: signalling
# at notice time would start the replacement ~75s earlier but races ASG
# termination against `compose stop` plus sync, which is the SQLite cut this
# drain exists to prevent. detach_data_volume no-ops itself when EBS_VOLUME_ID
# is empty (boot glue incomplete).
drain_for_spot() {
  load_env
  log "Spot interruption notice received; stopping the data-volume writers..."
  if ! claim_drain; then
    log "A drain is already running."
    return 0
  fi
  stop_writers "$SPOT_GRACE"
  detach_data_volume
  set_unhealthy
  finish_drain
}

# The ASG is already terminating the instance, so no Unhealthy mark.
drain_for_termination() {
  load_env
  if ! instance_terminating; then
    log "Not an ASG termination; leaving the shutdown to systemd."
    return 0
  fi
  if ! claim_drain; then
    log "A drain is already running; waiting for it."
    await_drain
    return 0
  fi
  log "ASG termination; stopping the data-volume writers..."
  stop_writers "$STOP_GRACE"
  detach_data_volume
  finish_drain
}

main() {
  _main_code=""
  _main_token=""
  log "Watching $IMDS/meta-data/spot/instance-action every ${POLL_SECONDS}s..."
  while :; do
    if [ -z "$_main_token" ]; then
      _main_token="$(imds_token)" || _main_token=""
    fi
    if [ -n "$_main_token" ]; then
      _main_code="$(curl -s -o /dev/null -w '%{http_code}' -m 2 \
        -H "X-aws-ec2-metadata-token: $_main_token" \
        "$IMDS/meta-data/spot/instance-action")" || _main_code=000
      case "$_main_code" in
      200)
        drain_for_spot
        return 0
        ;;
      401) _main_token="" ;; # Token expired; refetch next loop.
      esac
    fi
    sleep "$POLL_SECONDS"
  done
}

case "${1:-}" in
'') main ;;
stop) drain_for_termination ;;
*)
  echo "usage: $0 [stop]" >&2
  exit 2
  ;;
esac
