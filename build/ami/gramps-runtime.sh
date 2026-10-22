#!/bin/sh
# Shared helpers for the AMI-baked watchdogs (spot-drain.sh, health-watchdog.sh,
# rightsize-watchdog.sh): IMDSv2 token/instance-id, marking the instance
# Unhealthy in the ASG, detaching the data volume ahead of replacement, and
# polling the runtime-only SSM parameter that lets Terraform change a
# watchdog's config without touching the launch template.
# Installed by build/ami/install.sh at /usr/local/lib/gramps-runtime.sh.
# Callers define their own log() before sourcing this; set -eu is the
# caller's to own.
# shellcheck shell=sh

readonly IMDS="http://169.254.169.254/latest"
readonly RUNTIME_ENV="/run/gramps-runtime.env"
readonly RUNTIME_STAMP="/run/gramps-runtime-stamp"

imds_token() {
  curl -sf -m 2 -X PUT "$IMDS/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"
}

# $1 = IMDS token. Echoes the instance ID.
imds_instance_id() {
  curl -sf -m 2 -H "X-aws-ec2-metadata-token: $1" "$IMDS/meta-data/instance-id"
}

# Best-effort, always returns 0. Fetches SSM_INSTANCE_RUNTIME_PARAM into
# $RUNTIME_ENV and sources it, cached on $RUNTIME_STAMP's mtime with a 300s
# floor -- the same idiom health-watchdog.sh's publish_host_metrics already
# uses for METRICS_STAMP, so the timer's 60s cadence costs one SSM read per
# five minutes. A fetch failure keeps the stale cache; with no cache yet, the
# values stay unset -- every caller already tolerates that
# (${STATUS_HOST_METRICS:-false}, rightsize-watchdog's
# ${RIGHTSIZE_MIN_UPTIME_HOURS:-3}). Requires REGION and
# SSM_INSTANCE_RUNTIME_PARAM already loaded from instance.env. Must run after
# load_env and before publish_host_metrics, and never in the health-check
# path itself.
load_runtime_env() {
  _load_runtime_env_now="$(date +%s)"
  _load_runtime_env_stamp_mtime="$(stat -c%Y "$RUNTIME_STAMP" 2>/dev/null || echo 0)"
  if [ "$((_load_runtime_env_now - _load_runtime_env_stamp_mtime))" -ge 300 ]; then
    if aws ssm get-parameter \
      --name "$SSM_INSTANCE_RUNTIME_PARAM" \
      --query 'Parameter.Value' --output text \
      --region "$REGION" >"$RUNTIME_ENV.tmp" 2>/dev/null; then
      mv "$RUNTIME_ENV.tmp" "$RUNTIME_ENV"
      touch "$RUNTIME_STAMP"
    else
      rm -f "$RUNTIME_ENV.tmp"
    fi
  fi
  if [ -f "$RUNTIME_ENV" ]; then
    # shellcheck disable=SC1090
    . "$RUNTIME_ENV"
  fi
  return 0
}

# Detaches the data volume so the ASG's replacement can attach it immediately
# instead of waiting for AWS to release it after termination. Stops the
# health-watchdog timer first: disk_bytes would otherwise measure the root
# filesystem through the vacated mountpoint and publish it as the data
# volume. Requires GRAMPS_DATA_ROOT, EBS_VOLUME_ID and REGION from
# instance.env. A no-op when EBS_VOLUME_ID is empty (boot glue
# incomplete) -- guarded here, once, so every caller (gramps-spot-drain,
# gramps-rightsize-watchdog) gets it for free rather than needing its own
# check.
detach_data_volume() {
  if [ -z "${EBS_VOLUME_ID:-}" ]; then
    log "no EBS_VOLUME_ID; nothing to detach"
    return 0
  fi
  systemctl stop gramps-health-watchdog.timer ||
    log "failed to stop gramps-health-watchdog.timer; continuing"
  umount "$GRAMPS_DATA_ROOT" ||
    log "umount $GRAMPS_DATA_ROOT failed; continuing"
  aws ec2 detach-volume --volume-id "$EBS_VOLUME_ID" --region "$REGION"
}

# Marks the instance Unhealthy in the ASG so it is replaced immediately
# instead of waiting on the next EC2/health-check cycle. $1 = optional
# cause-attribution marker parameter name (watchdog_markers.tf); omit it for
# a caller that must not claim attribution for another cause -- spot-drain
# passes none, since classify_cause() already checks spot-reclaim ahead of
# health-watchdog and a marker here would misattribute a real reclaim.
set_unhealthy() {
  _set_unhealthy_marker_time=""
  _set_unhealthy_marker_param="${1:-}"
  _set_unhealthy_token="$(imds_token)"
  _set_unhealthy_instance_id="$(imds_instance_id "$_set_unhealthy_token")"

  if [ -n "$_set_unhealthy_marker_param" ]; then
    _set_unhealthy_marker_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if ! aws ssm put-parameter \
      --name "$_set_unhealthy_marker_param" \
      --value "{\"time\":\"$_set_unhealthy_marker_time\",\"instance_id\":\"$_set_unhealthy_instance_id\"}" \
      --type String \
      --overwrite \
      --region "$REGION"; then
      log "Failed to write marker to $_set_unhealthy_marker_param; continuing anyway."
    fi
  fi

  log "Marking $_set_unhealthy_instance_id Unhealthy in the ASG..."
  aws autoscaling set-instance-health \
    --instance-id "$_set_unhealthy_instance_id" \
    --health-status Unhealthy \
    --region "$REGION"
}
