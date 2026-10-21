#!/bin/sh
# Out-of-band surgery on the gramps-web data volume: move it to another AZ, or
# re-encrypt it under a new KMS key. Both replace the volume, and the volume is
# prevent_destroy, so neither can be an ordinary apply.
#
# The shape is the same for both: snapshot the live volume, restore the copy
# out-of-band, adopt it into Terraform state, then leave the apply for YOU to
# review. Terraform never destroys the data, and the original volume is kept
# until you delete it.
#
# Subcommands (run in order; stop and inspect between each):
#   score                     Spot placement scores per AZ, to pick a target (read-only)
#   prepare <new-az>          TAKES THE SITE DOWN: scale ASG to 0, snapshot,
#                             restore a gp3 volume from the snapshot in <new-az>
#   rekey   [kms-key-id]      TAKES THE SITE DOWN: scale ASG to 0, snapshot,
#                             copy it re-encrypted under <kms-key-id> (default:
#                             the stack's ebs_kms_key_arn), restore in the SAME AZ
#   shrink  <size-gb>         TAKES THE SITE DOWN: snapshot (fallback), attach a
#                             blank <size-gb> volume to the RUNNING instance,
#                             stop the app, rsync the tree across, detach, THEN
#                             scale ASG to 0 -- same AZ and key as the live volume
#   adopt   <new-vol> <az>    back up state, swap the volume in state, set az in
#                             tfvars -> then YOU run terraform plan / apply
#   finish  [url]             AFTER your apply: scale ASG to 1, wait InService,
#                             optionally poll <url> for health
#
# So an AZ move is score -> prepare -> adopt -> apply -> finish, and a re-key is
# rekey -> adopt -> apply -> finish. `rekey` re-encrypts a volume under a
# customer-managed KMS key (modules/storage/aws_kms_key.data), required for
# cross-account backup. See docs/cross-account-backup.md.
#
# `shrink` differs from prepare/rekey in shape, not intent: EBS cannot restore a
# larger snapshot into a smaller volume, so there is no snapshot-and-restore
# path down. Instead it copies files onto a blank volume attached alongside the
# live one, which is why the app-stop (for a quiescent source tree) comes
# BEFORE the copy rather than never, and why the ASG doesn't scale to 0 until
# AFTER the copy -- unlike prepare/rekey, which have nothing left to read from
# the live volume once they start. shrink -> adopt -> apply -> finish.
#
# Manual steps this script will NOT do, by design:
#   - choosing the AZ (use `score`, then your judgement)
#   - terraform apply (you review the plan first)
#   - scaling up before apply (the AttachVolume IAM policy is scoped to the
#     volume ARN; it must be updated by apply before the new volume can attach)
#   - deleting the old volume (keep it as a fallback for a few days)
#
# Env: ENV (default prod; selects terraform/config/stack/<env>), AWS_REGION (default:
#      primary_region from the env's tfvars), INSTANCE_TYPES (space-separated,
#      for `score`; default: the types the live ASG's requirements resolve to), FORCE=1 (skip
#      prompts).
set -eu

SCRIPT_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly SCRIPT_DIR
REPO_ROOT="$(dirname -- "$SCRIPT_DIR")"
readonly REPO_ROOT

readonly LOG_PREFIX="azmove"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

env_paths
REGION="$(resolve_region "$TFVARS")"
readonly REGION
readonly VOL_RESOURCE="module.storage.aws_ebs_volume.this"
# cmd_finish's waits: 60 ticks x 10s = ~10 min each, which covers a Spot
# capacity wait plus the on-boot CodeDeploy run.
readonly WAIT_TICKS=60
readonly WAIT_SECONDS=10

# cmd_shrink's second attach point (the live volume is always /dev/sdf, see
# modules/compute/user_data.sh.tftpl) and the guest-side mountpoint for the
# copy.
readonly SHRINK_DEVICE="/dev/sdg"
readonly SHRINK_MOUNT="/mnt/gramps-shrink"

# Cross-function state: cleanup_shrink's EXIT trap needs both to decide
# whether to bring the app back up on the instance it stopped it on.
SHRINK_APP_STOPPED=0
SHRINK_INSTANCE=""

validate_az() {
  aws ec2 describe-availability-zones --region "$REGION" \
    --query 'AvailabilityZones[].ZoneName' --output text |
    tr '\t' '\n' | grep -qx "$1" || die "'$1' is not an availability zone in $REGION"
}

# volume_attr VOL JMESPATH -> the attribute on stdout, e.g.
# `volume_attr vol-1 AvailabilityZone`.
volume_attr() {
  aws ec2 describe-volumes --region "$REGION" --volume-ids "$1" \
    --query "Volumes[0].$2" --output text
}

# $1 = desired capacity (also the floor, so the ASG cannot scale back on its
# own mid-move).
scale_asg() {
  local asg
  asg="$1"
  log "Scaling $asg to $2..."
  aws autoscaling update-auto-scaling-group --region "$REGION" \
    --auto-scaling-group-name "$asg" --min-size "$2" --desired-capacity "$2"
}

# --- score -------------------------------------------------------------------

# Instance types to score. $INSTANCE_TYPES (explicit override) wins; otherwise
# resolve the live ASG's per-arch instance requirements to types, so the score
# measures what the ASG can actually launch. Resolving them live keeps this the
# single source of truth: a baked-in copy here is exactly the kind of list that
# drifts when the derived spec in modules/compute changes.
score_types() {
  local asg count i req types all
  if [ -n "${INSTANCE_TYPES:-}" ]; then
    echo "$INSTANCE_TYPES"
    return 0
  fi
  asg="$(tf_output asg_name)"
  count="$(aws autoscaling describe-auto-scaling-groups --region "$REGION" \
    --auto-scaling-group-names "$asg" \
    --query 'length(AutoScalingGroups[0].MixedInstancesPolicy.LaunchTemplate.Overrides)' \
    --output text)"
  req="$(mktemp)"
  all=""
  i=0
  while [ "$i" -lt "$count" ]; do
    aws autoscaling describe-auto-scaling-groups --region "$REGION" \
      --auto-scaling-group-names "$asg" \
      --query "AutoScalingGroups[0].MixedInstancesPolicy.LaunchTemplate.Overrides[$i].InstanceRequirements" \
      --output json >"$req"
    types="$(aws ec2 get-instance-types-from-instance-requirements \
      --region "$REGION" \
      --architecture-types arm64 x86_64 --virtualization-types hvm \
      --instance-requirements "file://$req" \
      --query 'InstanceTypes[].InstanceType' --output text)"
    all="$all $types"
    i=$((i + 1))
  done
  rm -f "$req"
  all="$(echo "$all" | tr -s ' \t' '\n' | sort -u | tr '\n' ' ')"
  [ -n "$all" ] ||
    die "no instance types resolved for ASG '$asg'; set INSTANCE_TYPES explicitly"
  echo "$all"
}

# $1 = space-separated instance types. Word splitting is the interface here,
# as it is in the ASG config.
fetch_spot_scores() {
  # shellcheck disable=SC2086
  aws ec2 get-spot-placement-scores --region "$REGION" \
    --instance-types $1 \
    --target-capacity 1 \
    --single-availability-zone \
    --region-names "$REGION" \
    --output json
}

# $1 = get-spot-placement-scores JSON. The API reports zone IDs, which are
# per-account; map them back to the zone names the operator actually types.
render_scores() {
  local azmap
  azmap="$(aws ec2 describe-availability-zones --region "$REGION" \
    --query 'AvailabilityZones[].{id:ZoneId,name:ZoneName}' --output json)"
  echo "AZ            SCORE"
  echo "$1" | jq -r --argjson m "$azmap" '
    ($m | map({(.id): .name}) | add) as $names
    | .SpotPlacementScores
    | sort_by(-.Score)[]
    | "\($names[.AvailabilityZoneId] // .AvailabilityZoneId)  \(.Score)"'
}

cmd_score() {
  local types
  types="$(score_types)"
  log "Spot placement scores in $REGION (1-10, higher is better; account- and"
  log "time-specific, NOT a guarantee). Instance types: $types"
  render_scores "$(fetch_spot_scores "$types")"
}

# --- prepare -----------------------------------------------------------------

# snapshot_volume VOL DESCRIPTION -> snapshot id on stdout, once complete.
snapshot_volume() {
  local snap
  log "Creating snapshot of $1..."
  snap="$(aws ec2 create-snapshot --region "$REGION" --volume-id "$1" \
    --description "$2" \
    --tag-specifications "ResourceType=snapshot,Tags=[{Key=Project,Value=gramps-web},{Key=Name,Value=gramps-data-azmove}]" \
    --query 'SnapshotId' --output text)"
  log "Snapshot $snap created; waiting for completion (may take several minutes)..."
  aws ec2 wait snapshot-completed --region "$REGION" --snapshot-ids "$snap"
  echo "$snap"
}

# restore_volume SNAPSHOT AZ -> new volume id on stdout, once available.
# Project=gramps-web is REQUIRED: the instance role's AttachVolume is gated on
# that tag. Persistent=true drives nothing (AWS Backup selects the volume by
# ARN) but is kept so the restored volume matches what modules/storage declares.
restore_volume() {
  local new_vol
  log "Creating gp3 volume from $1 in $2..."
  new_vol="$(aws ec2 create-volume --region "$REGION" \
    --snapshot-id "$1" --availability-zone "$2" --volume-type gp3 \
    --tag-specifications "ResourceType=volume,Tags=[{Key=Project,Value=gramps-web},{Key=Persistent,Value=true},{Key=Name,Value=gramps-data}]" \
    --query 'VolumeId' --output text)"
  aws ec2 wait volume-available --region "$REGION" --volume-ids "$new_vol"
  echo "$new_vol"
}

cmd_prepare() {
  local new_az asg vol cur_az snap new_vol
  [ "$#" -eq 1 ] || die "usage: $0 prepare <new-az>"
  new_az="$1"
  validate_az "$new_az"

  asg="$(tf_output asg_name)"
  vol="$(tf_output ebs_volume_id)"
  cur_az="$(volume_attr "$vol" AvailabilityZone)"
  [ "$cur_az" != "$new_az" ] || die "volume $vol is already in $new_az"

  log "ASG=$asg  volume=$vol  move $cur_az -> $new_az"
  confirm "Scale the ASG to 0 (THE SITE GOES DOWN), then snapshot and restore the volume into $new_az?"

  scale_asg "$asg" 0
  log "Waiting for the data volume to detach (state: available)..."
  aws ec2 wait volume-available --region "$REGION" --volume-ids "$vol"

  snap="$(snapshot_volume "$vol" "azmove $cur_az->$new_az $(date -u +%Y%m%d%H%M%S)")"
  new_vol="$(restore_volume "$snap" "$new_az")"

  log "New volume ready: $new_vol (in $new_az)"
  log "Original volume $vol is untouched, in $cur_az."
  log "Next: $0 adopt $new_vol $new_az"
}

# --- rekey -------------------------------------------------------------------

# rekey_snapshot SNAP KEY -> re-encrypted snapshot id on stdout, once complete.
# EBS has no re-key-in-place API: copying the snapshot under a new key and
# restoring from the copy is the only path AWS offers. The copy is a full one
# (it crosses a key boundary), so it is slower than the incremental snapshot
# before it -- minutes on a 20 GB volume.
rekey_snapshot() {
  local copy
  log "Copying snapshot $1, re-encrypted under $2..."
  copy="$(aws ec2 copy-snapshot --region "$REGION" \
    --source-region "$REGION" --source-snapshot-id "$1" \
    --encrypted --kms-key-id "$2" \
    --description "rekey of $1" \
    --tag-specifications "ResourceType=snapshot,Tags=[{Key=Project,Value=gramps-web},{Key=Name,Value=gramps-data-rekey}]" \
    --query 'SnapshotId' --output text)"
  log "Snapshot copy $copy created; waiting for completion (may take several minutes)..."
  aws ec2 wait snapshot-completed --region "$REGION" --snapshot-ids "$copy"
  echo "$copy"
}

cmd_rekey() {
  local key asg vol cur_az cur_key snap copy new_vol
  [ "$#" -le 1 ] || die "usage: $0 rekey [kms-key-id]"
  key="${1:-}"
  # Default to the key the stack declares, so the common case cannot typo its
  # way onto a key the volume config does not name -- which would make the
  # post-adopt plan want to replace the volume it just adopted.
  [ -n "$key" ] || key="$(tf_output ebs_kms_key_arn)"

  asg="$(tf_output asg_name)"
  vol="$(tf_output ebs_volume_id)"
  cur_az="$(volume_attr "$vol" AvailabilityZone)"
  cur_key="$(volume_attr "$vol" KmsKeyId)"
  [ "$cur_key" != "$key" ] ||
    die "volume $vol is already encrypted under $key; nothing to do"

  log "ASG=$asg  volume=$vol  AZ=$cur_az (unchanged by a re-key)"
  log "  from key: $cur_key"
  log "    to key: $key"
  confirm "Scale the ASG to 0 (THE SITE GOES DOWN), then snapshot the volume and restore it re-encrypted in $cur_az?"

  scale_asg "$asg" 0
  log "Waiting for the data volume to detach (state: available)..."
  aws ec2 wait volume-available --region "$REGION" --volume-ids "$vol"

  snap="$(snapshot_volume "$vol" "rekey $(date -u +%Y%m%d%H%M%S)")"
  copy="$(rekey_snapshot "$snap" "$key")"
  new_vol="$(restore_volume "$copy" "$cur_az")"

  log "New volume ready: $new_vol (in $cur_az, under $key)"
  log "Original volume $vol is untouched, still on $cur_key -- it is your rollback."
  log "Next: $0 adopt $new_vol $cur_az"
}

# --- shrink ------------------------------------------------------------------

# EXIT trap while the app is stopped on the live instance: a shrink that
# succeeds is SUPPOSED to leave the app down (the site stays down through
# adopt/apply/finish), so this only restarts it when the exit status is
# nonzero -- an abort or a mid-copy failure, where the live instance is still
# the one serving and must come back up.
cleanup_shrink() {
  local status
  status=$?
  if [ "$SHRINK_APP_STOPPED" = 1 ] && [ "$status" != 0 ]; then
    log "Shrink did not complete; bringing the app back up on $SHRINK_INSTANCE..."
    ssm_run "$SHRINK_INSTANCE" "gramps shrink: restart app" "$START_CMD" ||
      log "ERROR: restart failed. On the instance, run: $START_CMD"
  fi
  exit "$status"
}

# create_blank_volume SIZE_GB AZ KEY_ARN -> new blank gp3 volume id on stdout,
# once available. KEY_ARN empty means aws/ebs -- mirrors modules/storage's own
# `encrypted = true, kms_key_id = null` under backup.mode != cross_account.
create_blank_volume() {
  local size az key new_vol
  size="$1"
  az="$2"
  key="$3"
  log "Creating blank ${size}GiB gp3 volume in $az..."
  if [ -n "$key" ]; then
    new_vol="$(aws ec2 create-volume --region "$REGION" \
      --availability-zone "$az" --volume-type gp3 --size "$size" \
      --encrypted --kms-key-id "$key" \
      --tag-specifications "ResourceType=volume,Tags=[{Key=Project,Value=gramps-web},{Key=Persistent,Value=true},{Key=Name,Value=gramps-data}]" \
      --query 'VolumeId' --output text)"
  else
    new_vol="$(aws ec2 create-volume --region "$REGION" \
      --availability-zone "$az" --volume-type gp3 --size "$size" \
      --encrypted \
      --tag-specifications "ResourceType=volume,Tags=[{Key=Project,Value=gramps-web},{Key=Persistent,Value=true},{Key=Name,Value=gramps-data}]" \
      --query 'VolumeId' --output text)"
  fi
  aws ec2 wait volume-available --region "$REGION" --volume-ids "$new_vol"
  echo "$new_vol"
}

# copy_script NEW_VOL_ID -> a shell script on stdout, to run on the instance
# both volumes are attached to: find the new volume's block device by NVMe
# serial (same technique as user_data.sh.tftpl's find_block_device, for the
# second device rather than the boot-time one), format it, mount it, and
# rsync the live tree across. GRAMPS_DATA_ROOT comes from instance.env rather
# than being duplicated here.
copy_script() {
  local serial
  serial="$(echo "$1" | tr -d '-')"
  cat <<SH
set -eu
. /etc/gramps/instance.env
serial_target="$serial"
dev=""
i=0
while [ "\$i" -lt 60 ]; do
  for ctrl in /sys/class/nvme/nvme*; do
    [ -r "\$ctrl/serial" ] || continue
    if [ "\$(tr -d ' ' <"\$ctrl/serial")" = "\$serial_target" ]; then
      dev="/dev/\$(basename "\$ctrl")n1"
    fi
  done
  [ -z "\$dev" ] || break
  i=\$((i + 1))
  sleep 1
done
[ -n "\$dev" ] && [ -b "\$dev" ] || { echo "block device for $1 did not appear within 60s" >&2; exit 1; }
echo "Formatting ext4 on \$dev..."
mkfs.ext4 -m 0 -E lazy_itable_init=0,lazy_journal_init=0 "\$dev"
mkdir -p "$SHRINK_MOUNT"
mount "\$dev" "$SHRINK_MOUNT"
echo "Copying \$GRAMPS_DATA_ROOT -> $SHRINK_MOUNT..."
rsync -aHAX --numeric-ids "\$GRAMPS_DATA_ROOT/" "$SHRINK_MOUNT/"
umount "$SHRINK_MOUNT"
echo "Copy complete."
SH
}

cmd_shrink() {
  local size asg vol cur_az cur_size key snap new_vol
  [ "$#" -eq 1 ] || die "usage: $0 shrink <size-gb>"
  size="$1"
  case "$size" in '' | *[!0-9]*) die "size-gb must be a positive integer" ;; esac

  asg="$(tf_output asg_name)"
  vol="$(tf_output ebs_volume_id)"
  cur_az="$(volume_attr "$vol" AvailabilityZone)"
  cur_size="$(volume_attr "$vol" Size)"
  key="$(tf_output_opt ebs_kms_key_arn)"
  [ "$size" -lt "$cur_size" ] ||
    die "size-gb ($size) must be smaller than the live volume's size ($cur_size) -- EBS grows in place (ModifyVolume); this is only for shrinking"

  SHRINK_INSTANCE="$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$vol" \
    --query 'Volumes[0].Attachments[0].InstanceId' --output text)"
  [ "$SHRINK_INSTANCE" != "None" ] || die "$vol is not attached to a running instance"

  log "ASG=$asg  volume=$vol (${cur_size}GiB, $cur_az)  instance=$SHRINK_INSTANCE  target=${size}GiB"
  confirm "Snapshot $vol as a fallback, attach a blank ${size}GiB volume to $SHRINK_INSTANCE, stop the app, copy the tree across, then scale the ASG to 0? (THE SITE GOES DOWN from the app stop through your apply + finish)"

  snap="$(snapshot_volume "$vol" "shrink fallback $(date -u +%Y%m%d%H%M%S)")"
  log "Fallback snapshot: $snap -- keep it a few days, then delete by hand."

  new_vol="$(create_blank_volume "$size" "$cur_az" "$key")"
  log "Attaching $new_vol at $SHRINK_DEVICE on $SHRINK_INSTANCE..."
  aws ec2 attach-volume --region "$REGION" --volume-id "$new_vol" \
    --instance-id "$SHRINK_INSTANCE" --device "$SHRINK_DEVICE" >/dev/null
  aws ec2 wait volume-in-use --region "$REGION" --volume-ids "$new_vol"

  trap cleanup_shrink EXIT
  log "Stopping the app on $SHRINK_INSTANCE..."
  SHRINK_APP_STOPPED=1
  ssm_run "$SHRINK_INSTANCE" "gramps shrink: stop app" "$STOP_CMD" ||
    die "could not stop the app cleanly; not copying"

  log "Formatting $new_vol and copying the tree onto it..."
  ssm_run "$SHRINK_INSTANCE" "gramps shrink: copy tree" "$(copy_script "$new_vol")" ||
    die "copy failed; app left stopped -- rerun after fixing, or restart by hand: $START_CMD"

  log "Detaching $new_vol from $SHRINK_INSTANCE..."
  aws ec2 detach-volume --region "$REGION" --volume-id "$new_vol" >/dev/null
  aws ec2 wait volume-available --region "$REGION" --volume-ids "$new_vol"

  log "Scaling $asg to 0 (the site's downtime, which started at the app stop above, continues through adopt/apply/finish)..."
  scale_asg "$asg" 0
  trap - EXIT

  log "New volume ready: $new_vol (${size}GiB, $cur_az)"
  log "Original volume $vol is untouched, still ${cur_size}GiB -- your rollback, plus snapshot $snap."
  log "Next: $0 adopt $new_vol $cur_az"
}

# --- adopt -------------------------------------------------------------------

# Refuse to adopt a volume that is in the wrong AZ or that the instance role
# could not attach; both are silent-failure-at-boot otherwise.
verify_new_volume() {
  local v_az proj
  v_az="$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$1" \
    --query 'Volumes[0].AvailabilityZone' --output text)" ||
    die "volume $1 not found"
  [ "$v_az" = "$2" ] || die "$1 is in $v_az, not $2"

  proj="$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$1" \
    --query "Volumes[0].Tags[?Key=='Project']|[0].Value" --output text)"
  [ "$proj" = "gramps-web" ] ||
    die "$1 lacks tag Project=gramps-web; the instance role cannot attach it"
}

# -> backup path on stdout.
backup_state() {
  local backup
  backup="$SCRIPT_DIR/azmove-state-$(date -u +%Y%m%d%H%M%S).json"
  log "Backing up Terraform state to $backup..."
  tf state pull >"$backup"
  echo "$backup"
}

# Point $VOL_RESOURCE at the restored volume without letting Terraform touch
# either AWS resource: rm leaves the old volume intact, import adopts the new.
swap_volume_in_state() {
  log "Removing old volume from state (the AWS resource is left intact)..."
  tf state rm "$VOL_RESOURCE"
  log "Importing $1 as $VOL_RESOURCE..."
  tf import -var-file="$TFVARS" "$VOL_RESOURCE" "$1"
}

set_tfvars_az() {
  local tmp
  if grep -Eq '^[[:space:]]*az[[:space:]]*=' "$TFVARS"; then
    log "Updating az in $TFVARS..."
    tmp="$(mktemp)"
    sed -E "s|^([[:space:]]*az[[:space:]]*=).*|\\1 \"$1\"|" "$TFVARS" >"$tmp"
    mv "$tmp" "$TFVARS"
  else
    log "Adding az to $TFVARS..."
    printf '\naz = "%s"\n' "$1" >>"$TFVARS"
  fi
}

cmd_adopt() {
  local new_vol new_az backup
  [ "$#" -eq 2 ] || die "usage: $0 adopt <new-vol-id> <new-az>"
  new_vol="$1"
  new_az="$2"
  validate_az "$new_az"
  verify_new_volume "$new_vol" "$new_az"

  backup="$(backup_state)"
  confirm "Swap $VOL_RESOURCE in state to $new_vol? (state surgery; backup at $backup)"
  swap_volume_in_state "$new_vol"
  set_tfvars_az "$new_az"

  log "State and tfvars updated. NOW DO THIS BY HAND:"
  log "  1) scripts/tf.sh $ENV plan"
  log "     Verify: the data volume is a NO-OP (NOT destroyed); the launch"
  log "     template and AttachVolume IAM policy update to the new volume ARN."
  log "     After an AZ move the public subnet is also replaced (empty, safe);"
  log "     after a re-key nothing else should move at all."
  log "     If the volume shows destroy or replace, STOP."
  log "  2) scripts/tf.sh $ENV apply"
  log "  3) $0 finish [https://your-site/]"
}

# --- finish ------------------------------------------------------------------

wait_for_inservice() {
  local state i
  log "Waiting for an InService instance (up to ~10 min)..."
  i=0
  while [ "$i" -lt "$WAIT_TICKS" ]; do
    state="$(aws autoscaling describe-auto-scaling-groups --region "$REGION" \
      --auto-scaling-group-names "$1" \
      --query 'AutoScalingGroups[0].Instances[0].LifecycleState' \
      --output text 2>/dev/null || echo None)"
    if [ "$state" = "InService" ]; then
      log "Instance InService."
      return 0
    fi
    i=$((i + 1))
    sleep "$WAIT_SECONDS"
  done
  die "no InService instance after timeout; check the ASG"
}

# Exhausting the poll is a failure, not a pass: an InService instance whose
# deploy failed still serves nothing.
wait_for_healthy() {
  local code i
  log "Polling $1 (CodeDeploy runs on boot; allow a few minutes)..."
  code=000
  i=0
  while [ "$i" -lt "$WAIT_TICKS" ]; do
    code="$(curl -o /dev/null -s -w '%{http_code}' --max-time 5 "$1" || echo 000)"
    case "$code" in
    2[0-9][0-9] | 3[0-9][0-9])
      log "Healthy (HTTP $code)."
      return 0
      ;;
    esac
    i=$((i + 1))
    sleep "$WAIT_SECONDS"
  done
  die "no healthy response from $1 after ~10 min (last: HTTP $code); the instance is InService but the deploy may have failed -- check CodeDeploy"
}

cmd_finish() {
  local url asg
  url="${1:-}"
  asg="$(tf_output asg_name)"

  scale_asg "$asg" 1
  wait_for_inservice "$asg"
  [ -z "$url" ] || wait_for_healthy "$url"

  log "Move complete. Remaining MANUAL steps:"
  log "  - Verify the site loads and the tree data is intact."
  log "  - After a few days of confidence, delete the OLD volume:"
  log "      aws ec2 delete-volume --region $REGION --volume-id <old-vol-id>"
  log "  - prevent_destroy on the volume stays in config; nothing to re-add."
}

# --- dispatch ----------------------------------------------------------------

main() {
  local cmd
  require aws terraform jq curl
  [ "$#" -ge 1 ] || usage
  cmd="$1"
  shift
  case "$cmd" in
  score) cmd_score "$@" ;;
  prepare) cmd_prepare "$@" ;;
  rekey) cmd_rekey "$@" ;;
  shrink) cmd_shrink "$@" ;;
  adopt) cmd_adopt "$@" ;;
  finish) cmd_finish "$@" ;;
  *) die "unknown subcommand '$cmd' (expected: score|prepare|rekey|shrink|adopt|finish)" ;;
  esac
}

main "$@"
