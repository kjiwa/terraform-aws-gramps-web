#!/bin/sh
# App-level self-healing. The ASG's EC2 health check only catches a broken
# INSTANCE; a dead app on a healthy instance (gunicorn wedged, docker dead)
# is invisible to it. This runs every minute from gramps-health-watchdog.timer
# and, after THRESHOLD consecutive local failures, marks the instance
# Unhealthy so the ASG replaces it (and CodeDeploy redeploys on the new one).
#
# THRESHOLD=10 (~10 min) is deliberately generous: first boot reaches healthy
# in ~3-5 min, a CodeDeploy rolling update flaps localhost for well under a
# minute, and a Spot drain kills the instance ~2 min after stopping the
# containers -- none of those get near 10. Only a genuinely stuck app does.
# If the bug ships in the revision itself, the replacement will also fail and
# this fires again every ~10 min; the site-down alarm stays in ALARM the whole
# time, so that shows up as one long outage with repeated ASG activity.
#
# set_unhealthy is not a general rescue: it detects the dead app correctly
# even while the instance is still mid-launch (e.g. stuck in Pending:Wait
# behind a hung CodeDeploy lifecycle hook, systemd timer running regardless),
# but SetInstanceHealth is a no-op there -- the ASG only acts on Unhealthy for
# an instance that has already completed its launch activity and gone
# InService. A launch stuck that way is bounded by the ASG's own handling
# (instance_refresh's alarm_specification, asg.tf), not by this script.
#
# Installed by build/ami/install.sh as /usr/local/bin/gramps-health-watchdog.
set -eu

readonly URL="http://localhost/"
readonly COUNT_FILE="/run/gramps-health-failcount"
readonly METRICS_STAMP="/run/gramps-host-metrics-stamp"
readonly INSTANCE_ENV="/etc/gramps/instance.env"
readonly THRESHOLD=10

log() {
  echo "[health-watchdog] $*"
}

# shellcheck source=gramps-runtime.sh
. /usr/local/lib/gramps-runtime.sh

# Boot glue not finished: the app legitimately isn't up yet; don't count.
load_env() {
  [ -f "$INSTANCE_ENV" ] || exit 0
  # shellcheck disable=SC1090
  . "$INSTANCE_ENV"
}

app_healthy() {
  local code
  code="$(curl -o /dev/null -s -w '%{http_code}' --max-time 5 "$URL" || echo 000)"
  case "$code" in
  2[0-9][0-9] | 3[0-9][0-9]) return 0 ;;
  esac
  log "Local check failed (HTTP $code)."
  return 1
}

# Consecutive-failure count, in /run so a reboot starts clean. Echoes the new
# count.
bump_failures() {
  local count
  count="$(cat "$COUNT_FILE" 2>/dev/null || echo 0)"
  count=$((count + 1))
  echo "$count" >"$COUNT_FILE"
  echo "$count"
}

# $1: mountpoint. Echoes "<bytes used> <filesystem size in bytes>". df
# right-pads narrow columns with leading spaces on a filesystem small enough
# for the values to be short (confirmed against /dev/shm), so the two fields
# are split via unquoted word-splitting (set --), not fixed-width slicing.
disk_bytes() {
  local mount
  mount="$1"
  # shellcheck disable=SC2046 # word-splitting is the point: two digit fields.
  set -- $(df -B1 --output=used,size "$mount" | tail -1)
  printf '%s %s\n' "$1" "$2"
}

# Optional, additive: publishes disk/memory usage to the GrampsWeb CloudWatch
# namespace for the status page's host_metrics panel (modules/
# status). No ASG dimension -- this is a single-instance deployment, same as
# the availability canary's SiteUp metric. Gated on STATUS_HOST_METRICS,
# polled via load_runtime_env from the instance_runtime SSM parameter
# (terraform's status_host_metrics -> "true"/"false"), and throttled to once
# per 5 minutes via a stamp file's mtime, not a wall-clock minute check:
# gramps-health-watchdog.timer's OnUnitActiveSec=60 + AccuracySec=15 makes
# real intervals run 60-75s, which periodically skips past a fixed minute
# mark entirely and would leave gaps in the published metrics.
#
# The disk series is picked by STATUS_VOLUME_METRICS, mutually exclusive
# with no overlap: off (default) publishes DiskUsedPercent for the data
# volume alone; on publishes DiskUsedBytes/DiskTotalBytes for both the data
# volume and root, each with a Mount=data|root dimension, and stops publishing
# DiskUsedPercent (the byte pair supersedes it; both would double-pay for the
# same reading). An instance without STATUS_VOLUME_METRICS in its environment
# publishes DiskUsedPercent, as this script is Packer-baked and takes effect
# on the next base-AMI rebuild.
publish_host_metrics() {
  local mem_pct now stamp_mtime disk_pct data_used data_size root_used root_size

  [ "${STATUS_HOST_METRICS:-false}" = "true" ] || return 0

  now="$(date +%s)"
  stamp_mtime="$(stat -c%Y "$METRICS_STAMP" 2>/dev/null || echo 0)"
  [ "$((now - stamp_mtime))" -ge 300 ] || return 0

  mem_pct="$(awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {if (t > 0) printf "%.1f", (t - a) / t * 100}' /proc/meminfo)"

  if [ "${STATUS_VOLUME_METRICS:-false}" = "true" ]; then
    # shellcheck disable=SC2046 # word-splitting is the point: two digit fields.
    set -- $(disk_bytes "$GRAMPS_DATA_ROOT")
    data_used="$1"
    data_size="$2"
    # shellcheck disable=SC2046
    set -- $(disk_bytes /)
    root_used="$1"
    root_size="$2"
    set -- \
      "MetricName=DiskUsedBytes,Dimensions=[{Name=Mount,Value=data}],Value=${data_used:-0},Unit=Bytes" \
      "MetricName=DiskTotalBytes,Dimensions=[{Name=Mount,Value=data}],Value=${data_size:-0},Unit=Bytes" \
      "MetricName=DiskUsedBytes,Dimensions=[{Name=Mount,Value=root}],Value=${root_used:-0},Unit=Bytes" \
      "MetricName=DiskTotalBytes,Dimensions=[{Name=Mount,Value=root}],Value=${root_size:-0},Unit=Bytes" \
      "MetricName=MemUsedPercent,Value=${mem_pct:-0},Unit=Percent"
  else
    disk_pct="$(df --output=pcent "$GRAMPS_DATA_ROOT" | tail -1 | tr -d ' %')"
    set -- \
      "MetricName=DiskUsedPercent,Value=${disk_pct:-0},Unit=Percent" \
      "MetricName=MemUsedPercent,Value=${mem_pct:-0},Unit=Percent"
  fi

  if aws cloudwatch put-metric-data \
    --region "$REGION" \
    --namespace GrampsWeb \
    --metric-data "$@"; then
    touch "$METRICS_STAMP"
  else
    log "Failed to publish host metrics."
  fi
}

main() {
  local count
  load_env
  # Never in the health-check path: app_healthy() below must reflect only the
  # localhost check, not an SSM outage. load_runtime_env is best-effort and
  # always returns 0, but it stays out of that decision on principle.
  load_runtime_env
  publish_host_metrics

  if app_healthy; then
    rm -f "$COUNT_FILE"
    return 0
  fi

  count="$(bump_failures)"
  log "$count/$THRESHOLD consecutive failures."
  if [ "$count" -ge "$THRESHOLD" ]; then
    # LAST_HEALTH_WATCHDOG_PARAM comes from instance.env (terraform's compute
    # module owns the parameter; see watchdog_markers.tf), written BEFORE the
    # ASG call so the outage this triggers can be attributed to the health
    # watchdog instead of falling through to "unknown".
    set_unhealthy "$LAST_HEALTH_WATCHDOG_PARAM"
    rm -f "$COUNT_FILE"
  fi
}

main "$@"
