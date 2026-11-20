#!/bin/sh
# Points the gramps-web launch templates at the newest base AMI per
# architecture and starts an instance refresh when a running instance's AMI is
# older than AMI_MAX_AGE_DAYS. Runs as a post_build step of the gramps-web-ami
# CodeBuild project (build/ami/buildspec.yml), after the Packer smoke check
# has passed.
#
# For each architecture: when the template's latest version is not on the
# newest AMI, write a new version copying it with only ImageId replaced (no
# description), then repoint the group's template pins at the new numeric
# versions. The group stays pinned to a version, never $Latest, so a template
# change made by Terraform still starts a refresh.
#
# A template the group is not pinned to the latest version of (a rollback or
# hold set by hand) is held: its version is still written, the group keeps its
# pin, a HELD line is logged and AmiAdoptionHeld is published. The other
# template is adopted. Nothing is touched while a refresh runs or a refresh
# alarm is in ALARM. Versions beyond the newest KEEP_VERSIONS, except
# the default and the pinned one, are deleted so scripts/clean-amis.sh, which
# keeps every AMI a version references, can free old AMIs.
#
# Env (all set by the CodeBuild project):
#   REGION               region of the group and templates.
#   ADOPT_AMIS           "true" to act; anything else exits 0 (ami_ids pinned).
#   ASG_NAME             the Auto Scaling group.
#   LAUNCH_TEMPLATE_IDS  JSON object, architecture to launch template id.
#   REFRESH_ALARM_NAMES  JSON list of alarms the refresh watches.
#   AMI_MAX_AGE_DAYS     refresh only when a running AMI is older than this.
#   NOW                  epoch seconds; defaults to the current time (tests).
set -eu

readonly LOG_PREFIX="adopt-amis"
readonly AMI_TAG_NAME="gramps-web-base"
readonly METRIC_NAMESPACE="GrampsWeb"
readonly KEEP_VERSIONS=5

SCRIPT_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly SCRIPT_DIR
# shellcheck source=keel/common.sh
. "$SCRIPT_DIR/keel/common.sh"

# Base AMIs as the describe-images JSON, kept whole: it also dates the AMIs the
# instances run.
list_images() {
  aws ec2 describe-images --region "$REGION" --owners self \
    --filters "Name=tag:Name,Values=$AMI_TAG_NAME" "Name=state,Values=available" \
    --output json
}

# $1 = images JSON, $2 = architecture. The newest AMI id, or nothing.
newest_ami() {
  printf '%s' "$1" | jq -r --arg a "$2" \
    '[.Images[] | select(.Architecture == $a)] | max_by(.CreationDate) | .ImageId // empty'
}

# $1 = template id. "<version> <image id>" of its latest version.
latest_version() {
  # shellcheck disable=SC2016 # $Latest is a literal API selector
  aws ec2 describe-launch-template-versions --region "$REGION" \
    --launch-template-id "$1" --versions '$Latest' --output json |
    jq -r '.LaunchTemplateVersions[0] | "\(.VersionNumber) \(.LaunchTemplateData.ImageId)"'
}

# $1 = template id, $2 = source version, $3 = AMI id. Echoes the new version.
write_version() {
  aws ec2 create-launch-template-version --region "$REGION" \
    --launch-template-id "$1" --source-version "$2" \
    --launch-template-data "{\"ImageId\":\"$3\"}" --output json |
    jq -r '.LaunchTemplateVersion.VersionNumber'
}

# $1 = group JSON, $2 = template id. The version the group pins it to.
pinned_version() {
  printf '%s' "$1" | jq -r --arg id "$2" \
    '.AutoScalingGroups[0].MixedInstancesPolicy.LaunchTemplate
     | [.LaunchTemplateSpecification, (.Overrides[]?.LaunchTemplateSpecification)]
     | map(select(.LaunchTemplateId == $id)) | first | .Version'
}

# $1 = group JSON, $2 = JSON object of template id to version. The group's
# mixed instances policy with those versions set and template names dropped.
repinned_policy() {
  printf '%s' "$1" | jq -c --argjson v "$2" '
    def pin: del(.LaunchTemplateName) | if $v[.LaunchTemplateId] then .Version = $v[.LaunchTemplateId] else . end;
    .AutoScalingGroups[0].MixedInstancesPolicy
    | .LaunchTemplate.LaunchTemplateSpecification |= pin
    | .LaunchTemplate.Overrides |= (. // [] | map(if .LaunchTemplateSpecification then .LaunchTemplateSpecification |= pin else . end))'
}

# $1 = group JSON. Image ids of the live instances, space-separated.
running_images() {
  _running_images_ids="$(printf '%s' "$1" | jq -r \
    '[.AutoScalingGroups[0].Instances[] | select(.LifecycleState | IN("InService", "Pending", "Pending:Wait", "Pending:Proceed")) | .InstanceId] | join(" ")')"
  [ -n "$_running_images_ids" ] || return 0
  # Word-splitting is the point: one argument per instance id.
  # shellcheck disable=SC2086
  aws ec2 describe-instances --region "$REGION" --instance-ids $_running_images_ids --output json |
    jq -r '[.Reservations[].Instances[].ImageId] | unique | join(" ")'
}

# $1 = images JSON, $2 = space-separated image ids. Age in days of each of
# those images the account still has, one per line.
image_ages() {
  printf '%s' "$1" | jq -r --argjson now "$NOW" --arg ids "$2" '
    .Images[] | select(.ImageId | IN($ids | split(" ")[]))
    | (($now - (.CreationDate | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)) / 86400 * 100 | round) / 100'
}

# $1 = metric name, $2 = value. Best effort: a metric failure must not stop the
# adoption.
publish_metric() {
  aws cloudwatch put-metric-data --region "$REGION" --namespace "$METRIC_NAMESPACE" \
    --metric-data "MetricName=$1,Dimensions=[{Name=AutoScalingGroupName,Value=$ASG_NAME}],Value=$2,Unit=None" ||
    log "could not publish $1; continuing"
}

# Echoes why the group must not be touched, or nothing.
blocker() {
  _blocker_status="$(aws autoscaling describe-instance-refreshes --region "$REGION" \
    --auto-scaling-group-name "$ASG_NAME" --output json |
    jq -r '[.InstanceRefreshes[].Status | select(IN("Pending", "InProgress", "Cancelling", "RollbackInProgress", "Baking"))] | first // empty')"
  if [ -n "$_blocker_status" ]; then
    echo "an instance refresh is $_blocker_status"
    return 0
  fi
  _blocker_alarms="$(printf '%s' "$REFRESH_ALARM_NAMES" | jq -r '.[]')"
  [ -n "$_blocker_alarms" ] || return 0
  # shellcheck disable=SC2086
  aws cloudwatch describe-alarms --region "$REGION" --alarm-names $_blocker_alarms --output json |
    jq -r '[.MetricAlarms[] | select(.StateValue == "ALARM") | .AlarmName] | if length > 0 then "alarm in ALARM: " + join(", ") else empty end'
}

# $1 = template id, $2 = what the group pins it to: a number, or a selector such
# as $Latest that matches no number. Deletes versions beyond the newest
# KEEP_VERSIONS, except the default and the pinned one.
prune_versions() {
  _prune_versions_doomed="$(aws ec2 describe-launch-template-versions --region "$REGION" \
    --launch-template-id "$1" --output json |
    jq -r --argjson keep "$KEEP_VERSIONS" --arg pinned "$2" '
      .LaunchTemplateVersions | sort_by(-.VersionNumber)
      | to_entries | map(select(.key >= $keep and (.value.DefaultVersion | not) and (.value.VersionNumber | tostring) != $pinned))
      | map(.value.VersionNumber) | sort | map(tostring) | join(" ")')"
  [ -n "$_prune_versions_doomed" ] || return 0
  log "deleting $1 versions: $_prune_versions_doomed"
  # shellcheck disable=SC2086
  aws ec2 delete-launch-template-versions --region "$REGION" \
    --launch-template-id "$1" --versions $_prune_versions_doomed >/dev/null
}

# $1 = images JSON, $2 = space-separated running image ids, $3 = space-separated
# newest AMI ids, $4 = space-separated architectures the group is following
# (not held). True when a running AMI of one of those is older than the limit
# and is not one of the newest.
needs_refresh() {
  for _needs_refresh_image in $2; do
    in_list "$_needs_refresh_image" "$3" && continue
    _needs_refresh_arch="$(printf '%s' "$1" | jq -r --arg id "$_needs_refresh_image" '.Images[] | select(.ImageId == $id) | .Architecture')"
    in_list "$_needs_refresh_arch" "$4" || continue
    _needs_refresh_age="$(image_ages "$1" "$_needs_refresh_image")"
    [ -n "$_needs_refresh_age" ] || continue
    [ "$(jq -n --argjson a "$_needs_refresh_age" --argjson m "$AMI_MAX_AGE_DAYS" 'if $a > $m then 1 else 0 end')" -eq 1 ] && return 0
  done
  return 1
}

# in_list ITEM "a b c": ITEM is one of the space-separated words.
in_list() {
  case " $2 " in *" $1 "*) return 0 ;; esac
  return 1
}

start_refresh() {
  _start_refresh_id="$(aws autoscaling start-instance-refresh --region "$REGION" \
    --auto-scaling-group-name "$ASG_NAME" --strategy Rolling \
    --preferences "$(printf '%s' "$REFRESH_ALARM_NAMES" | jq -c '{MinHealthyPercentage: 0, AlarmSpecification: {Alarms: .}}')" \
    --query InstanceRefreshId --output text)"
  log "started instance refresh $_start_refresh_id"
}

# $1 = images JSON, $2 = running image ids. Echoes the age of the oldest.
oldest_running_age() {
  [ -n "$2" ] || return 0
  image_ages "$1" "$2" | sort -n | tail -n 1
}

main() {
  require aws jq
  if [ "${ADOPT_AMIS:-false}" != true ]; then
    log "adoption is off (ami_ids pins the AMIs); nothing to do."
    return 0
  fi
  : "${REGION:?REGION is required}" "${ASG_NAME:?ASG_NAME is required}"
  : "${LAUNCH_TEMPLATE_IDS:?LAUNCH_TEMPLATE_IDS is required}" "${REFRESH_ALARM_NAMES:?REFRESH_ALARM_NAMES is required}"
  : "${AMI_MAX_AGE_DAYS:?AMI_MAX_AGE_DAYS is required}"
  NOW="${NOW:-$(date +%s)}"

  _main_images="$(list_images)"
  _main_group="$(aws autoscaling describe-auto-scaling-groups --region "$REGION" \
    --auto-scaling-group-names "$ASG_NAME" --output json)"
  _main_archs="$(printf '%s' "$LAUNCH_TEMPLATE_IDS" | jq -r 'keys | join(" ")')"

  _main_running="$(running_images "$_main_group")"
  _main_age="$(oldest_running_age "$_main_images" "$_main_running")"
  [ -z "$_main_age" ] || publish_metric AmiAgeDays "$_main_age"

  _main_blocker="$(blocker)"
  if [ -n "$_main_blocker" ]; then
    log "skipping: $_main_blocker."
    return 0
  fi

  _main_newest=""
  for _main_arch in $_main_archs; do
    _main_target="$(newest_ami "$_main_images" "$_main_arch")"
    [ -n "$_main_target" ] || die "no available $AMI_TAG_NAME AMI for $_main_arch in $REGION"
    _main_newest="$_main_newest $_main_target"
  done

  _main_pins="{}"
  _main_effective="{}"
  _main_held_count=0
  _main_active=""
  for _main_arch in $_main_archs; do
    _main_lt="$(printf '%s' "$LAUNCH_TEMPLATE_IDS" | jq -r --arg a "$_main_arch" '.[$a]')"
    _main_target="$(newest_ami "$_main_images" "$_main_arch")"
    _main_latest="$(latest_version "$_main_lt")"
    _main_version="${_main_latest%% *}"
    _main_pinned="$(pinned_version "$_main_group" "$_main_lt")"
    _main_new="$_main_version"
    if [ "${_main_latest#* }" != "$_main_target" ]; then
      _main_new="$(write_version "$_main_lt" "$_main_version" "$_main_target")"
      log "$_main_lt ($_main_arch): version $_main_new uses $_main_target (was ${_main_latest#* })"
    fi
    if [ "$_main_pinned" = "$_main_version" ]; then
      _main_active="$_main_active $_main_arch"
      _main_effective="$(printf '%s' "$_main_effective" | jq -c --arg lt "$_main_lt" --arg v "$_main_new" '. + {($lt): $v}')"
      [ "$_main_new" = "$_main_version" ] ||
        _main_pins="$(printf '%s' "$_main_pins" | jq -c --arg lt "$_main_lt" --arg v "$_main_new" '. + {($lt): $v}')"
    else
      log "HELD: $_main_lt ($_main_arch) is pinned to $_main_pinned, not the latest version $_main_version; the group keeps that pin."
      _main_held_count=$((_main_held_count + 1))
      _main_effective="$(printf '%s' "$_main_effective" | jq -c --arg lt "$_main_lt" --arg v "$_main_pinned" '. + {($lt): $v}')"
    fi
  done
  publish_metric AmiAdoptionHeld "$_main_held_count"

  if [ "$_main_pins" != "{}" ]; then
    aws autoscaling update-auto-scaling-group --region "$REGION" \
      --auto-scaling-group-name "$ASG_NAME" \
      --mixed-instances-policy "$(repinned_policy "$_main_group" "$_main_pins")"
    log "repinned $ASG_NAME: $_main_pins"
  fi
  if needs_refresh "$_main_images" "$_main_running" "$_main_newest" "$_main_active"; then
    start_refresh
  fi

  for _main_lt in $(printf '%s' "$_main_effective" | jq -r 'keys[]'); do
    prune_versions "$_main_lt" "$(printf '%s' "$_main_effective" | jq -r --arg lt "$_main_lt" '.[$lt]')"
  done
}

main "$@"
