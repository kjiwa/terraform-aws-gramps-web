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
#   adopt   <new-vol> <az>    back up state, swap the volume in state -> then YOU
#                             set az on the module, run terraform plan / apply
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
# Root: --root DIR, or $GRAMPS_WEB_ROOT, is the Terraform root that
#       instantiates the module (see common.sh). Place it before the subcommand.
#       `adopt` runs terraform import, which evaluates the root's configuration:
#       set TF_CLI_ARGS_import (for example -var-file=...) if it needs variables.
# Env:  INSTANCE_TYPES (space-separated, for `score`; default: the types the
#       live ASG's requirements resolve to), FORCE=1 (skip prompts).
# Files: `adopt` writes a state backup, azmove-state-*.json, to the current
#       directory.
set -eu

SCRIPT_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly SCRIPT_DIR

readonly LOG_PREFIX="azmove"
# shellcheck source=keel/common.sh
. "$SCRIPT_DIR/keel/common.sh"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

readonly VOL_RESOURCE_SUFFIX="module.storage.aws_ebs_volume.this"
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
  _scale_asg_asg="$1"
  log "Scaling $_scale_asg_asg to $2..."
  aws autoscaling update-auto-scaling-group --region "$REGION" \
    --auto-scaling-group-name "$_scale_asg_asg" --min-size "$2" --desired-capacity "$2"
}

# --- score -------------------------------------------------------------------

# Instance types to score. $INSTANCE_TYPES (explicit override) wins; otherwise
# resolve the live ASG's per-arch instance requirements to types, so the score
# measures what the ASG can actually launch. Resolving them live keeps this the
# single source of truth: a baked-in copy here is exactly the kind of list that
# drifts when the derived spec in modules/compute changes.
score_types() {
  _score_types_types=""
  if [ -n "${INSTANCE_TYPES:-}" ]; then
    echo "$INSTANCE_TYPES"
    return 0
  fi
  _score_types_asg="$(tf_output asg_name)"
  _score_types_count="$(aws autoscaling describe-auto-scaling-groups --region "$REGION" \
    --auto-scaling-group-names "$_score_types_asg" \
    --query 'length(AutoScalingGroups[0].MixedInstancesPolicy.LaunchTemplate.Overrides)' \
    --output text)"
  _score_types_req="$(mktemp)"
  _score_types_all=""
  _score_types_i=0
  while [ "$_score_types_i" -lt "$_score_types_count" ]; do
    aws autoscaling describe-auto-scaling-groups --region "$REGION" \
      --auto-scaling-group-names "$_score_types_asg" \
      --query "AutoScalingGroups[0].MixedInstancesPolicy.LaunchTemplate.Overrides[$_score_types_i].InstanceRequirements" \
      --output json >"$_score_types_req"
    _score_types_types="$(aws ec2 get-instance-types-from-instance-requirements \
      --region "$REGION" \
      --architecture-types arm64 x86_64 --virtualization-types hvm \
      --instance-requirements "file://$_score_types_req" \
      --query 'InstanceTypes[].InstanceType' --output text)"
    _score_types_all="$_score_types_all $_score_types_types"
    _score_types_i=$((_score_types_i + 1))
  done
  rm -f "$_score_types_req"
  _score_types_all="$(echo "$_score_types_all" | tr -s ' \t' '\n' | sort -u | tr '\n' ' ')"
  [ -n "$_score_types_all" ] ||
    die "no instance types resolved for ASG '$_score_types_asg'; set INSTANCE_TYPES explicitly"
  echo "$_score_types_all"
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
  _render_scores_azmap="$(aws ec2 describe-availability-zones --region "$REGION" \
    --query 'AvailabilityZones[].{id:ZoneId,name:ZoneName}' --output json)"
  echo "AZ            SCORE"
  echo "$1" | jq -r --argjson m "$_render_scores_azmap" '
    ($m | map({(.id): .name}) | add) as $names
    | .SpotPlacementScores
    | sort_by(-.Score)[]
    | "\($names[.AvailabilityZoneId] // .AvailabilityZoneId)  \(.Score)"'
}

cmd_score() {
  _cmd_score_types="$(score_types)"
  log "Spot placement scores in $REGION (1-10, higher is better; account- and"
  log "time-specific, NOT a guarantee). Instance types: $_cmd_score_types"
  render_scores "$(fetch_spot_scores "$_cmd_score_types")"
}

# --- prepare -----------------------------------------------------------------

# snapshot_volume VOL DESCRIPTION -> snapshot id on stdout, once complete.
snapshot_volume() {
  log "Creating snapshot of $1..."
  _snapshot_volume_snap="$(aws ec2 create-snapshot --region "$REGION" --volume-id "$1" \
    --description "$2" \
    --tag-specifications "ResourceType=snapshot,Tags=[{Key=Project,Value=gramps-web},{Key=Name,Value=gramps-data-azmove}]" \
    --query 'SnapshotId' --output text)"
  log "Snapshot $_snapshot_volume_snap created; waiting for completion (may take several minutes)..."
  aws ec2 wait snapshot-completed --region "$REGION" --snapshot-ids "$_snapshot_volume_snap"
  echo "$_snapshot_volume_snap"
}

# restore_volume SNAPSHOT AZ -> new volume id on stdout, once available.
# Project=gramps-web is REQUIRED: the instance role's AttachVolume is gated on
# that tag. Persistent=true drives nothing (AWS Backup selects the volume by
# ARN) but is kept so the restored volume matches what modules/storage declares.
restore_volume() {
  log "Creating gp3 volume from $1 in $2..."
  _restore_volume_new_vol="$(aws ec2 create-volume --region "$REGION" \
    --snapshot-id "$1" --availability-zone "$2" --volume-type gp3 \
    --tag-specifications "ResourceType=volume,Tags=[{Key=Project,Value=gramps-web},{Key=Persistent,Value=true},{Key=Name,Value=gramps-data}]" \
    --query 'VolumeId' --output text)"
  aws ec2 wait volume-available --region "$REGION" --volume-ids "$_restore_volume_new_vol"
  echo "$_restore_volume_new_vol"
}

cmd_prepare() {
  [ "$#" -eq 1 ] || die "usage: $0 prepare <new-az>"
  _cmd_prepare_new_az="$1"
  validate_az "$_cmd_prepare_new_az"

  _cmd_prepare_asg="$(tf_output asg_name)"
  _cmd_prepare_vol="$(tf_output ebs_volume_id)"
  _cmd_prepare_cur_az="$(volume_attr "$_cmd_prepare_vol" AvailabilityZone)"
  [ "$_cmd_prepare_cur_az" != "$_cmd_prepare_new_az" ] || die "volume $_cmd_prepare_vol is already in $_cmd_prepare_new_az"

  log "ASG=$_cmd_prepare_asg  volume=$_cmd_prepare_vol  move $_cmd_prepare_cur_az -> $_cmd_prepare_new_az"
  confirm "Scale the ASG to 0 (THE SITE GOES DOWN), then snapshot and restore the volume into $_cmd_prepare_new_az?"

  scale_asg "$_cmd_prepare_asg" 0
  log "Waiting for the data volume to detach (state: available)..."
  aws ec2 wait volume-available --region "$REGION" --volume-ids "$_cmd_prepare_vol"

  _cmd_prepare_snap="$(snapshot_volume "$_cmd_prepare_vol" "azmove $_cmd_prepare_cur_az->$_cmd_prepare_new_az $(date -u +%Y%m%d%H%M%S)")"
  _cmd_prepare_new_vol="$(restore_volume "$_cmd_prepare_snap" "$_cmd_prepare_new_az")"

  log "New volume ready: $_cmd_prepare_new_vol (in $_cmd_prepare_new_az)"
  log "Original volume $_cmd_prepare_vol is untouched, in $_cmd_prepare_cur_az."
  log "Next: $0 --root $ROOT_DIR adopt $_cmd_prepare_new_vol $_cmd_prepare_new_az"
}

# --- rekey -------------------------------------------------------------------

# rekey_snapshot SNAP KEY -> re-encrypted snapshot id on stdout, once complete.
# EBS has no re-key-in-place API: copying the snapshot under a new key and
# restoring from the copy is the only path AWS offers. The copy is a full one
# (it crosses a key boundary), so it is slower than the incremental snapshot
# before it -- minutes on a 20 GB volume.
rekey_snapshot() {
  log "Copying snapshot $1, re-encrypted under $2..."
  _rekey_snapshot_copy="$(aws ec2 copy-snapshot --region "$REGION" \
    --source-region "$REGION" --source-snapshot-id "$1" \
    --encrypted --kms-key-id "$2" \
    --description "rekey of $1" \
    --tag-specifications "ResourceType=snapshot,Tags=[{Key=Project,Value=gramps-web},{Key=Name,Value=gramps-data-rekey}]" \
    --query 'SnapshotId' --output text)"
  log "Snapshot copy $_rekey_snapshot_copy created; waiting for completion (may take several minutes)..."
  aws ec2 wait snapshot-completed --region "$REGION" --snapshot-ids "$_rekey_snapshot_copy"
  echo "$_rekey_snapshot_copy"
}

cmd_rekey() {
  _cmd_rekey_key=""
  [ "$#" -le 1 ] || die "usage: $0 rekey [kms-key-id]"
  _cmd_rekey_key="${1:-}"
  # Default to the key the stack declares, so the common case cannot typo its
  # way onto a key the volume config does not name -- which would make the
  # post-adopt plan want to replace the volume it just adopted.
  [ -n "$_cmd_rekey_key" ] || _cmd_rekey_key="$(tf_output ebs_kms_key_arn)"

  _cmd_rekey_asg="$(tf_output asg_name)"
  _cmd_rekey_vol="$(tf_output ebs_volume_id)"
  _cmd_rekey_cur_az="$(volume_attr "$_cmd_rekey_vol" AvailabilityZone)"
  _cmd_rekey_cur_key="$(volume_attr "$_cmd_rekey_vol" KmsKeyId)"
  [ "$_cmd_rekey_cur_key" != "$_cmd_rekey_key" ] ||
    die "volume $_cmd_rekey_vol is already encrypted under $_cmd_rekey_key; nothing to do"

  log "ASG=$_cmd_rekey_asg  volume=$_cmd_rekey_vol  AZ=$_cmd_rekey_cur_az (unchanged by a re-key)"
  log "  from key: $_cmd_rekey_cur_key"
  log "    to key: $_cmd_rekey_key"
  confirm "Scale the ASG to 0 (THE SITE GOES DOWN), then snapshot the volume and restore it re-encrypted in $_cmd_rekey_cur_az?"

  scale_asg "$_cmd_rekey_asg" 0
  log "Waiting for the data volume to detach (state: available)..."
  aws ec2 wait volume-available --region "$REGION" --volume-ids "$_cmd_rekey_vol"

  _cmd_rekey_snap="$(snapshot_volume "$_cmd_rekey_vol" "rekey $(date -u +%Y%m%d%H%M%S)")"
  _cmd_rekey_copy="$(rekey_snapshot "$_cmd_rekey_snap" "$_cmd_rekey_key")"
  _cmd_rekey_new_vol="$(restore_volume "$_cmd_rekey_copy" "$_cmd_rekey_cur_az")"

  log "New volume ready: $_cmd_rekey_new_vol (in $_cmd_rekey_cur_az, under $_cmd_rekey_key)"
  log "Original volume $_cmd_rekey_vol is untouched, still on $_cmd_rekey_cur_key -- it is your rollback."
  log "Next: $0 --root $ROOT_DIR adopt $_cmd_rekey_new_vol $_cmd_rekey_cur_az"
}

# --- shrink ------------------------------------------------------------------

# EXIT trap while the app is stopped on the live instance: a shrink that
# succeeds is SUPPOSED to leave the app down (the site stays down through
# adopt/apply/finish), so this only restarts it when the exit status is
# nonzero -- an abort or a mid-copy failure, where the live instance is still
# the one serving and must come back up.
cleanup_shrink() {
  _cleanup_shrink_status=$?
  if [ "$SHRINK_APP_STOPPED" = 1 ] && [ "$_cleanup_shrink_status" != 0 ]; then
    log "Shrink did not complete; bringing the app back up on $SHRINK_INSTANCE..."
    ssm_run "$SHRINK_INSTANCE" "gramps shrink: restart app" "$START_CMD" ||
      log "ERROR: restart failed. On the instance, run: $START_CMD"
  fi
  exit "$_cleanup_shrink_status"
}

# create_blank_volume SIZE_GB AZ KEY_ARN -> new blank gp3 volume id on stdout,
# once available. KEY_ARN empty means aws/ebs -- mirrors modules/storage's own
# `encrypted = true, kms_key_id = null` under backup.mode != cross_account.
create_blank_volume() {
  _create_blank_volume_new_vol=""
  _create_blank_volume_size="$1"
  _create_blank_volume_az="$2"
  _create_blank_volume_key="$3"
  log "Creating blank ${_create_blank_volume_size}GiB gp3 volume in $_create_blank_volume_az..."
  if [ -n "$_create_blank_volume_key" ]; then
    _create_blank_volume_new_vol="$(aws ec2 create-volume --region "$REGION" \
      --availability-zone "$_create_blank_volume_az" --volume-type gp3 --size "$_create_blank_volume_size" \
      --encrypted --kms-key-id "$_create_blank_volume_key" \
      --tag-specifications "ResourceType=volume,Tags=[{Key=Project,Value=gramps-web},{Key=Persistent,Value=true},{Key=Name,Value=gramps-data}]" \
      --query 'VolumeId' --output text)"
  else
    _create_blank_volume_new_vol="$(aws ec2 create-volume --region "$REGION" \
      --availability-zone "$_create_blank_volume_az" --volume-type gp3 --size "$_create_blank_volume_size" \
      --encrypted \
      --tag-specifications "ResourceType=volume,Tags=[{Key=Project,Value=gramps-web},{Key=Persistent,Value=true},{Key=Name,Value=gramps-data}]" \
      --query 'VolumeId' --output text)"
  fi
  aws ec2 wait volume-available --region "$REGION" --volume-ids "$_create_blank_volume_new_vol"
  echo "$_create_blank_volume_new_vol"
}

# copy_script NEW_VOL_ID -> a shell script on stdout, to run on the instance
# both volumes are attached to: find the new volume's block device by NVMe
# serial (same technique as user_data.sh.tftpl's find_block_device, for the
# second device rather than the boot-time one), format it, mount it, and
# rsync the live tree across. GRAMPS_DATA_ROOT comes from instance.env rather
# than being duplicated here.
copy_script() {
  _copy_script_serial="$(echo "$1" | tr -d '-')"
  cat <<SH
set -eu
. /etc/gramps/instance.env
serial_target="$_copy_script_serial"
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
  _cmd_shrink_size=""
  [ "$#" -eq 1 ] || die "usage: $0 shrink <size-gb>"
  _cmd_shrink_size="$1"
  case "$_cmd_shrink_size" in '' | *[!0-9]*) die "size-gb must be a positive integer" ;; esac

  _cmd_shrink_asg="$(tf_output asg_name)"
  _cmd_shrink_vol="$(tf_output ebs_volume_id)"
  _cmd_shrink_cur_az="$(volume_attr "$_cmd_shrink_vol" AvailabilityZone)"
  _cmd_shrink_cur_size="$(volume_attr "$_cmd_shrink_vol" Size)"
  _cmd_shrink_key="$(tf_output_opt ebs_kms_key_arn)"
  [ "$_cmd_shrink_size" -lt "$_cmd_shrink_cur_size" ] ||
    die "size-gb ($_cmd_shrink_size) must be smaller than the live volume's size ($_cmd_shrink_cur_size) -- EBS grows in place (ModifyVolume); this is only for shrinking"

  SHRINK_INSTANCE="$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$_cmd_shrink_vol" \
    --query 'Volumes[0].Attachments[0].InstanceId' --output text)"
  [ "$SHRINK_INSTANCE" != "None" ] || die "$_cmd_shrink_vol is not attached to a running instance"

  log "ASG=$_cmd_shrink_asg  volume=$_cmd_shrink_vol (${_cmd_shrink_cur_size}GiB, $_cmd_shrink_cur_az)  instance=$SHRINK_INSTANCE  target=${_cmd_shrink_size}GiB"
  confirm "Snapshot $_cmd_shrink_vol as a fallback, attach a blank ${_cmd_shrink_size}GiB volume to $SHRINK_INSTANCE, stop the app, copy the tree across, then scale the ASG to 0? (THE SITE GOES DOWN from the app stop through your apply + finish)"

  _cmd_shrink_snap="$(snapshot_volume "$_cmd_shrink_vol" "shrink fallback $(date -u +%Y%m%d%H%M%S)")"
  log "Fallback snapshot: $_cmd_shrink_snap -- keep it a few days, then delete by hand."

  _cmd_shrink_new_vol="$(create_blank_volume "$_cmd_shrink_size" "$_cmd_shrink_cur_az" "$_cmd_shrink_key")"
  log "Attaching $_cmd_shrink_new_vol at $SHRINK_DEVICE on $SHRINK_INSTANCE..."
  aws ec2 attach-volume --region "$REGION" --volume-id "$_cmd_shrink_new_vol" \
    --instance-id "$SHRINK_INSTANCE" --device "$SHRINK_DEVICE" >/dev/null
  aws ec2 wait volume-in-use --region "$REGION" --volume-ids "$_cmd_shrink_new_vol"

  trap cleanup_shrink EXIT
  log "Stopping the app on $SHRINK_INSTANCE..."
  SHRINK_APP_STOPPED=1
  ssm_run "$SHRINK_INSTANCE" "gramps shrink: stop app" "$STOP_CMD" ||
    die "could not stop the app cleanly; not copying"

  log "Formatting $_cmd_shrink_new_vol and copying the tree onto it..."
  ssm_run "$SHRINK_INSTANCE" "gramps shrink: copy tree" "$(copy_script "$_cmd_shrink_new_vol")" ||
    die "copy failed; app left stopped -- rerun after fixing, or restart by hand: $START_CMD"

  log "Detaching $_cmd_shrink_new_vol from $SHRINK_INSTANCE..."
  aws ec2 detach-volume --region "$REGION" --volume-id "$_cmd_shrink_new_vol" >/dev/null
  aws ec2 wait volume-available --region "$REGION" --volume-ids "$_cmd_shrink_new_vol"

  log "Scaling $_cmd_shrink_asg to 0 (the site's downtime, which started at the app stop above, continues through adopt/apply/finish)..."
  scale_asg "$_cmd_shrink_asg" 0
  trap - EXIT

  log "New volume ready: $_cmd_shrink_new_vol (${_cmd_shrink_size}GiB, $_cmd_shrink_cur_az)"
  log "Original volume $_cmd_shrink_vol is untouched, still ${_cmd_shrink_cur_size}GiB -- your rollback, plus snapshot $_cmd_shrink_snap."
  log "Next: $0 --root $ROOT_DIR adopt $_cmd_shrink_new_vol $_cmd_shrink_cur_az"
}

# --- adopt -------------------------------------------------------------------

# Refuse to adopt a volume that is in the wrong AZ or that the instance role
# could not attach; both are silent-failure-at-boot otherwise.
verify_new_volume() {
  _verify_new_volume_v_az="$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$1" \
    --query 'Volumes[0].AvailabilityZone' --output text)" ||
    die "volume $1 not found"
  [ "$_verify_new_volume_v_az" = "$2" ] || die "$1 is in $_verify_new_volume_v_az, not $2"

  _verify_new_volume_proj="$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$1" \
    --query "Volumes[0].Tags[?Key=='Project']|[0].Value" --output text)"
  [ "$_verify_new_volume_proj" = "gramps-web" ] ||
    die "$1 lacks tag Project=gramps-web; the instance role cannot attach it"
}

# -> backup path on stdout; the file lands in the current directory.
backup_state() {
  _backup_state_backup="azmove-state-$(date -u +%Y%m%d%H%M%S).json"
  log "Backing up Terraform state to $_backup_state_backup..."
  tf state pull >"$_backup_state_backup"
  echo "$_backup_state_backup"
}

# Point the volume's state address at the restored volume without letting
# Terraform touch either AWS resource: rm leaves the old volume intact, import
# adopts the new. $1 = state address, $2 = new volume id.
swap_volume_in_state() {
  log "Removing old volume from state (the AWS resource is left intact)..."
  tf state rm "$1"
  log "Importing $2 as $1..."
  tf import "$1" "$2"
}

cmd_adopt() {
  [ "$#" -eq 2 ] || die "usage: $0 adopt <new-vol-id> <new-az>"
  _cmd_adopt_new_vol="$1"
  _cmd_adopt_new_az="$2"
  validate_az "$_cmd_adopt_new_az"
  verify_new_volume "$_cmd_adopt_new_vol" "$_cmd_adopt_new_az"

  _cmd_adopt_address="$(state_address "$VOL_RESOURCE_SUFFIX")"
  _cmd_adopt_backup="$(backup_state)"
  confirm "Swap $_cmd_adopt_address in state to $_cmd_adopt_new_vol? (state surgery; backup at $_cmd_adopt_backup)"
  swap_volume_in_state "$_cmd_adopt_address" "$_cmd_adopt_new_vol"

  log "State updated. NOW DO THIS BY HAND:"
  log "  1) Set az = \"$_cmd_adopt_new_az\" on the module in your root (a re-key leaves az as is)."
  log "  2) terraform plan in $ROOT_DIR"
  log "     Verify: the data volume is a NO-OP (NOT destroyed); the launch"
  log "     template and AttachVolume IAM policy update to the new volume ARN."
  log "     After an AZ move the public subnet is also replaced (empty, safe);"
  log "     after a re-key nothing else should move at all."
  log "     If the volume shows destroy or replace, STOP."
  log "  3) terraform apply in $ROOT_DIR"
  log "  4) $0 --root $ROOT_DIR finish [https://your-site/]"
}

# --- finish ------------------------------------------------------------------

wait_for_inservice() {
  _wait_for_inservice_state=""
  log "Waiting for an InService instance (up to ~10 min)..."
  _wait_for_inservice_i=0
  while [ "$_wait_for_inservice_i" -lt "$WAIT_TICKS" ]; do
    _wait_for_inservice_state="$(aws autoscaling describe-auto-scaling-groups --region "$REGION" \
      --auto-scaling-group-names "$1" \
      --query 'AutoScalingGroups[0].Instances[0].LifecycleState' \
      --output text 2>/dev/null || echo None)"
    if [ "$_wait_for_inservice_state" = "InService" ]; then
      log "Instance InService."
      return 0
    fi
    _wait_for_inservice_i=$((_wait_for_inservice_i + 1))
    sleep "$WAIT_SECONDS"
  done
  die "no InService instance after timeout; check the ASG"
}

# Exhausting the poll is a failure, not a pass: an InService instance whose
# deploy failed still serves nothing.
wait_for_healthy() {
  log "Polling $1 (CodeDeploy runs on boot; allow a few minutes)..."
  _wait_for_healthy_code=000
  _wait_for_healthy_i=0
  while [ "$_wait_for_healthy_i" -lt "$WAIT_TICKS" ]; do
    _wait_for_healthy_code="$(curl -o /dev/null -s -w '%{http_code}' --max-time 5 "$1" || echo 000)"
    case "$_wait_for_healthy_code" in
    2[0-9][0-9] | 3[0-9][0-9])
      log "Healthy (HTTP $_wait_for_healthy_code)."
      return 0
      ;;
    esac
    _wait_for_healthy_i=$((_wait_for_healthy_i + 1))
    sleep "$WAIT_SECONDS"
  done
  die "no healthy response from $1 after ~10 min (last: HTTP $_wait_for_healthy_code); the instance is InService but the deploy may have failed -- check CodeDeploy"
}

cmd_finish() {
  _cmd_finish_url="${1:-}"
  _cmd_finish_asg="$(tf_output asg_name)"

  scale_asg "$_cmd_finish_asg" 1
  wait_for_inservice "$_cmd_finish_asg"
  [ -z "$_cmd_finish_url" ] || wait_for_healthy "$_cmd_finish_url"

  log "Move complete. Remaining MANUAL steps:"
  log "  - Verify the site loads and the tree data is intact."
  log "  - After a few days of confidence, delete the OLD volume:"
  log "      aws ec2 delete-volume --region $REGION --volume-id <old-vol-id>"
  log "  - prevent_destroy on the volume stays in config; nothing to re-add."
}

# --- dispatch ----------------------------------------------------------------

main() {
  require aws terraform jq curl
  select_root "$@"
  shift "$ROOT_SHIFT"
  init_root
  [ "$#" -ge 1 ] || usage
  _main_cmd="$1"
  shift
  case "$_main_cmd" in
  score) cmd_score "$@" ;;
  prepare) cmd_prepare "$@" ;;
  rekey) cmd_rekey "$@" ;;
  shrink) cmd_shrink "$@" ;;
  adopt) cmd_adopt "$@" ;;
  finish) cmd_finish "$@" ;;
  *) die "unknown subcommand '$_main_cmd' (expected: score|prepare|rekey|shrink|adopt|finish)" ;;
  esac
}

main "$@"
