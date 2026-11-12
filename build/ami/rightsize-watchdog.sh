#!/bin/sh
# Actuation half of the scale-back to the cheapest Spot pool. Fires on
# gramps-rightsize-watchdog.timer; the schedule comes from rightsize.schedule
# via a user-data drop-in, from daily (the default) down to hourly. Whether to
# replace is decided by keel-rightsize-check (keel's scripts/rightsize-check.sh,
# baked into the AMI); this script acts only on its exit 0.
#
# It drains only once every input the replacement needs is present: a missing
# one would abort after the containers stop and the volume detaches, an outage
# with no replacement queued.
#
# On replace it stops the data-volume writers cleanly (same reasoning and
# grace budget as gramps-spot-drain), syncs, detaches the data volume, and
# marks the instance Unhealthy so the ASG replaces it. Like any outage over
# ~2 min, the replacement trips the site-down alarm, so the DOWN/RECOVERED
# emails double as the audit trail that this acted.
#
# Failure story: if SetInstanceHealth errors after the containers are stopped,
# nothing here restarts them -- on purpose. gramps-health-watchdog sees
# localhost down and forces the same replacement ~10 minutes later, so the
# recovery path is the one that is already load-bearing.
#
# Installed by build/ami/install.sh as /usr/local/bin/gramps-rightsize-watchdog.
set -eu

readonly INSTANCE_ENV="${INSTANCE_ENV:-/etc/gramps/instance.env}"
readonly ASG_NAME="gramps-web"

log() {
  echo "[rightsize-watchdog] $*"
}

# shellcheck source=gramps-runtime.sh
. "${GRAMPS_RUNTIME_LIB:-/usr/local/lib/gramps-runtime.sh}"

# Boot glue not finished: acting on a half-configured instance helps nobody;
# the timer fires again next tick.
load_env() {
  [ -f "$INSTANCE_ENV" ] || exit 0
  # shellcheck disable=SC1090
  . "$INSTANCE_ENV"
  load_runtime_env
}

require_env() {
  [ -n "${REGION:-}" ] || skip_unset REGION
  [ -n "${LAST_RIGHTSIZE_PARAM:-}" ] || skip_unset LAST_RIGHTSIZE_PARAM
  [ -n "${COMPOSE_DIR:-}" ] || skip_unset COMPOSE_DIR
}

# $1 = name of the missing variable.
skip_unset() {
  log "$1 is unset in instance.env; not rightsizing."
  exit 0
}

# 30s grace each, mirroring gramps-spot-drain: the default 10s would cut a
# long celery task short, and unlike a Spot reclaim there is no 120s clock
# here, so being generous costs nothing.
drain() {
  log "Stopping the data-volume writers before replacement..."
  docker compose --env-file "$COMPOSE_DIR/.env" \
    -f "$COMPOSE_DIR/docker-compose.yml" \
    stop -t 30 grampsweb_celery grampsweb ||
    log "compose stop failed; syncing anyway"
  sync
}

# Exit 1 is the check's ordinary "stay"; any other status (usage, missing
# binary, an API error under its set -e) also stays but is logged, so a broken
# check shows in the journal.
check_says_replace() {
  _check_says_replace_status=0
  keel-rightsize-check "$REGION" "$ASG_NAME" "${RIGHTSIZE_MIN_UPTIME_HOURS:-3}" ||
    _check_says_replace_status=$?
  [ "$_check_says_replace_status" -eq 0 ] && return 0
  [ "$_check_says_replace_status" -eq 1 ] ||
    log "keel-rightsize-check exited $_check_says_replace_status; staying."
  return 1
}

main() {
  load_env
  require_env
  check_says_replace || exit 0
  log "A cheaper Spot pool is available; replacing this instance."
  drain
  # set_unhealthy writes the marker parameter BEFORE the ASG call, same
  # contract as health-watchdog.sh's marker.
  detach_data_volume
  set_unhealthy "$LAST_RIGHTSIZE_PARAM"
  log "Marked Unhealthy; the ASG replaces from the cheapest available pool."
}

main "$@"
