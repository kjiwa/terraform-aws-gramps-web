#!/bin/sh
# Scale-back to the cheapest acceptable Spot pool. The ASG's allocation
# strategy picks a pool only at LAUNCH: once a stockout of the cheap tier
# lands us on a bigger type, nothing native ever moves us back when the cheap
# pools recover, so a one-day stockout becomes a month of paying for a large.
# The accepted pattern is periodic forced replacement; this makes it
# conditional.
#
# Fires on gramps-rightsize-watchdog.timer; the schedule comes from
# rightsize_schedule in tfvars via a user-data drop-in, from daily (the
# default) down to hourly. Spot instances only: On-Demand has no allocation
# to re-run. It resolves the ASG's own instance requirements to the eligible
# types and compares current Spot prices in this instance's AZ: if the
# cheapest eligible pool costs at most PRICE_MARGIN of what this instance's
# type does (cheaper_pool_exists), it acts; otherwise it does nothing. No type
# list is kept anywhere, so newly released types are judged by price alone.
# Any API failure means stay. The uptime cooldown (uptime_ok) bounds an
# aggressive schedule from turning into replacement churn: skip until the
# instance is RIGHTSIZE_MIN_UPTIME_HOURS old (default 3). A failed rightsize starts the clock over on the
# replacement, so this bounds worst-case churn under ANY schedule; a daily
# schedule never hits it.
#
# Past the guard it stops the data-volume writers cleanly (same reasoning and
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

readonly INSTANCE_ENV="/etc/gramps/instance.env"
readonly ASG_NAME="gramps-web"
# Intra-tier price spread is about 10-20%, so a 25% margin keeps the cheap
# tier from trading places in a loop; t8i and every .large sit 30% or more
# above it and clear the bar.
readonly PRICE_MARGIN="0.75"

log() {
  echo "[rightsize-watchdog] $*"
}

# shellcheck source=gramps-runtime.sh
. /usr/local/lib/gramps-runtime.sh

# $1 = path under meta-data.
imds() {
  curl -sf -m 2 -H "X-aws-ec2-metadata-token: $TOKEN" "$IMDS/meta-data/$1"
}

# Boot glue not finished: type checking a half-configured instance helps
# nobody; the timer fires again next tick.
load_env() {
  [ -f "$INSTANCE_ENV" ] || exit 0
  # shellcheck disable=SC1090
  . "$INSTANCE_ENV"
  load_runtime_env
}

# Rightsizing re-runs SPOT allocation; on an On-Demand instance
# (spot_enabled = false) there is no cheaper pool to fall back to, only a
# pointless daily replacement. An unreadable IMDS also says no (the safe
# direction: no churn, retry next tick).
is_spot() {
  local lifecycle
  lifecycle="$(imds instance-life-cycle)" || lifecycle=""
  [ "$lifecycle" = "spot" ]
}

# Union of the types every ASG override's InstanceRequirements resolves to,
# space-separated. The requirements pass unchanged from
# describe-auto-scaling-groups to get-instance-types-from-instance-requirements.
eligible_types() {
  local count i req types all
  count="$(aws autoscaling describe-auto-scaling-groups --region "$REGION" \
    --auto-scaling-group-names "$ASG_NAME" \
    --query 'length(AutoScalingGroups[0].MixedInstancesPolicy.LaunchTemplate.Overrides)' \
    --output text)" || return 1
  req="$(mktemp)"
  all=""
  i=0
  while [ "$i" -lt "$count" ]; do
    aws autoscaling describe-auto-scaling-groups --region "$REGION" \
      --auto-scaling-group-names "$ASG_NAME" \
      --query "AutoScalingGroups[0].MixedInstancesPolicy.LaunchTemplate.Overrides[$i].InstanceRequirements" \
      --output json >"$req" || {
      rm -f "$req"
      return 1
    }
    types="$(aws ec2 get-instance-types-from-instance-requirements \
      --region "$REGION" \
      --architecture-types arm64 x86_64 --virtualization-types hvm \
      --instance-requirements "file://$req" \
      --query 'InstanceTypes[].InstanceType' --output text)" || {
      rm -f "$req"
      return 1
    }
    all="$all $types"
    i=$((i + 1))
  done
  rm -f "$req"
  echo "$all" | tr -s ' \t' '\n' | sort -u | tr '\n' ' '
}

# $1 = own instance type, $2 = AZ. Succeeds when the cheapest eligible Spot
# pool in the AZ costs at most PRICE_MARGIN of the own type's price. Any
# failure or missing price says no (stay).
cheaper_pool_exists() {
  local types prices verdict
  types="$(eligible_types)" || {
    log "Could not resolve the eligible types; staying."
    return 1
  }
  [ -n "$types" ] || return 1
  # shellcheck disable=SC2086
  prices="$(aws ec2 describe-spot-price-history --region "$REGION" \
    --availability-zone "$2" --start-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --product-descriptions "Linux/UNIX" --instance-types $types \
    --query 'SpotPriceHistory[].[InstanceType,SpotPrice]' \
    --output text)" || {
    log "Could not read Spot prices; staying."
    return 1
  }
  verdict="$(echo "$prices" | awk -v own="$1" -v margin="$PRICE_MARGIN" '
    NF == 2 {
      if ($1 == own) own_price = $2
      if (min_price == "" || $2 + 0 < min_price + 0) { min_price = $2; min_type = $1 }
    }
    END {
      if (own_price == "" || min_price == "") { print "unknown"; exit }
      printf "own=%s cheapest=%s(%s) ", own_price, min_type, min_price
      print (min_price + 0 <= own_price * margin) ? "replace" : "stay"
    }')"
  log "$1 in $2: $verdict"
  case "$verdict" in
  *replace) return 0 ;;
  esac
  return 1
}

# Churn bound. /proc/uptime's first field is seconds with a fractional part;
# strip it for POSIX arithmetic.
uptime_ok() {
  local min_uptime_h min_uptime_s uptime_s
  min_uptime_h="${RIGHTSIZE_MIN_UPTIME_HOURS:-3}"
  min_uptime_s=$((min_uptime_h * 3600))
  read -r uptime_s _ </proc/uptime
  uptime_s="${uptime_s%.*}"
  [ "$uptime_s" -ge "$min_uptime_s" ] && return 0
  log "A cheaper pool exists for $1, but uptime (${uptime_s}s) is under the ${min_uptime_h}h cooldown; retrying next tick."
  return 1
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

replace_instance() {
  local instance_id
  instance_id="$(imds instance-id)"
  log "A cheaper pool exists for $1; replacing $instance_id."
  drain
  # LAST_RIGHTSIZE_PARAM comes from instance.env (terraform's compute module
  # owns the parameter; see watchdog_markers.tf); set_unhealthy writes it
  # BEFORE the ASG call, same contract as health-watchdog.sh's marker.
  detach_data_volume
  set_unhealthy "$LAST_RIGHTSIZE_PARAM"
  log "Marked Unhealthy; the ASG replaces from the cheapest available pool."
}

main() {
  local current_type az
  load_env

  TOKEN="$(imds_token)"
  readonly TOKEN

  is_spot || exit 0
  current_type="$(imds instance-type)"
  az="$(imds placement/availability-zone)" || exit 0
  cheaper_pool_exists "$current_type" "$az" || exit 0
  uptime_ok "$current_type" || exit 0
  replace_instance "$current_type"
}

main "$@"
