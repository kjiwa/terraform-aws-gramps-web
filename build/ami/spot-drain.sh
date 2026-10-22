#!/bin/sh
# Polls IMDSv2 for the EC2 Spot interruption notice (issued ~2 min before
# reclaim) and, on notice, cleanly stops the containers that write to the
# gramps data volume, syncs, then detaches the data volume and marks the
# instance Unhealthy so the ASG launches the replacement immediately instead
# of waiting for the reclaim itself to terminate the instance. Turns a Spot
# reclaim from a crash-stop (SQLite cut mid-write, journal replay on next
# mount) into a clean shutdown, which also makes any backup taken near a
# reclaim trustworthy -- the daily AWS Backup plan and `scripts/backup.sh run`
# are both crash-consistent, and this is a large part of why that is an
# acceptable trade.
#
# Installed by build/ami/install.sh as /usr/local/bin/gramps-spot-drain, run by
# gramps-spot-drain.service. Covers Spot reclaims only: ASG terminations
# (instance refresh, scale-in) do not emit this notice.
set -eu

readonly INSTANCE_ENV="/etc/gramps/instance.env"
readonly POLL_SECONDS=5

log() {
  # stdout lands in the journal via the unit.
  echo "[spot-drain] $*"
}

# shellcheck source=gramps-runtime.sh
. /usr/local/lib/gramps-runtime.sh

drain() {
  log "Spot interruption notice received; stopping the data-volume writers..."
  if [ -f "$INSTANCE_ENV" ]; then
    # shellcheck disable=SC1090
    . "$INSTANCE_ENV"
  fi
  if [ -n "${COMPOSE_DIR:-}" ]; then
    # 30s grace each (compose stops them sequentially: celery, then web)
    # fits the ~120s budget with room for sync; the 10s default would cut
    # long celery tasks (exports, reindex) short.
    docker compose --env-file "$COMPOSE_DIR/.env" \
      -f "$COMPOSE_DIR/docker-compose.yml" \
      stop -t 30 grampsweb_celery grampsweb ||
      log "compose stop failed; syncing anyway"
  else
    log "no COMPOSE_DIR (boot glue incomplete); nothing to stop"
  fi
  sync
  log "Drain complete."

  # Detached and marked unhealthy only after the drain above: signalling at
  # notice time would start the replacement ~75s earlier but races ASG
  # termination against `compose stop -t 30` plus sync, which is the SQLite
  # cut this drain exists to prevent. detach_data_volume no-ops itself when
  # EBS_VOLUME_ID is empty (boot glue incomplete).
  detach_data_volume
  set_unhealthy
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
        drain
        return 0
        ;;
      401) _main_token="" ;; # Token expired; refetch next loop.
      esac
    fi
    sleep "$POLL_SECONDS"
  done
}

main "$@"
