#!/bin/sh
# Deregister superseded Packer base AMIs and delete their backing snapshots.
#
# build/ami/gramps-ami.pkr.hcl builds a timestamped gramps-web-base AMI per
# architecture on every rebuild; terraform deploys whichever IDs are pinned in
# ami_ids. Nothing native ever deregisters the superseded builds, so
# each rebuild strands two AMIs whose root-volume snapshots bill forever. This
# walks every AMI matching the same selector Packer tags with (self-owned,
# tag:Name=gramps-web-base, state=available) and removes all but the keep set:
#
#   - the newest AMI per architecture (the candidate for the next ami_ids
#     bump),
#   - any AMI referenced by a current gramps-web launch template version or a
#     running/pending gramps-web instance (this is what protects the currently
#     PINNED AMI once newer builds exist: the launch template holds the pin,
#     and a root snapshot must never be pulled out from under a live instance
#     or a template the ASG could still launch from).
#
# Any failure while building the keep set aborts before anything is deleted:
# a lost API call must not silently shrink the set of protected AMIs.
#
# Both modes print the full KEEP/DELETE split; --delete then prompts once
# (FORCE=1 skips) and executes. Runs automatically as a post_build step of
# the gramps-web-ami CodeBuild project (build/ami/buildspec.yml), so this is
# for an out-of-band cleanup or a dry-run check.
#
#   ./clean-amis.sh            # show the keep/delete split, change nothing
#   ./clean-amis.sh --delete   # deregister + delete snapshots, with prompt
#
# Region: $AWS_REGION when set (the CodeBuild case, which has no Terraform
#         root); otherwise the module's region, from --root DIR or
#         $GRAMPS_WEB_ROOT (see common.sh).
# Env:    FORCE=1 (skip the prompt).
set -eu

SCRIPT_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly SCRIPT_DIR

readonly LOG_PREFIX="clean-amis"
# shellcheck source=keel/common.sh
. "$SCRIPT_DIR/keel/common.sh"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

# The tag Packer stamps on every base AMI. Deliberately the tag, not the
# ami_name glob: an AMI copy keeps the name but drops the tags, so the glob
# would sweep in copies this script never built and should not touch.
readonly AMI_TAG_NAME="gramps-web-base"

TAB="$(printf '\t')"
readonly TAB

usage() {
  echo "usage: $0 [--root DIR] [--delete]" >&2
  exit 2
}

# All matching self-owned AMIs, oldest first, one JSON object per line:
# {id, name, arch, date, snaps: [snapshot ids]}. The aws call is a plain
# assignment so its failure is fatal under set -e (a pipe would mask it).
list_base_amis() {
  _list_base_amis_images="$(aws ec2 describe-images --region "$REGION" --owners self \
    --filters "Name=tag:Name,Values=$AMI_TAG_NAME" "Name=state,Values=available" \
    --query 'Images[].{id:ImageId,name:Name,arch:Architecture,date:CreationDate,snaps:BlockDeviceMappings[].Ebs.SnapshotId}' \
    --output json)"
  printf '%s\n' "$_list_base_amis_images" | jq -c 'sort_by(.date)[]'
}

# AMI ids referenced by a current gramps-web launch template version or a live
# gramps-web instance; these survive regardless of age. Whitespace-separated,
# possibly with duplicates (membership checks don't care). Every aws call
# stands alone -- no pipes, no `|| true` -- so a throttled or failed lookup
# aborts the script instead of silently yielding a short keep set.
list_in_use_amis() {
  _list_in_use_amis_lt=""
  aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Project,Values=gramps-web" \
    "Name=instance-state-name,Values=pending,running" \
    --query 'Reservations[].Instances[].ImageId' --output text
  _list_in_use_amis_lts="$(aws ec2 describe-launch-templates --region "$REGION" \
    --filters "Name=launch-template-name,Values=gramps-web-*" \
    --query 'LaunchTemplates[].LaunchTemplateId' --output text)"
  # $Latest is what the ASG launches from; $Default covers a pinned template.
  for _list_in_use_amis_lt in $_list_in_use_amis_lts; do
    # shellcheck disable=SC2016 # $Latest/$Default are literal API selectors
    aws ec2 describe-launch-template-versions --region "$REGION" \
      --launch-template-id "$_list_in_use_amis_lt" --versions '$Latest' '$Default' \
      --query 'LaunchTemplateVersions[].LaunchTemplateData.ImageId' \
      --output text
  done
}

# $1 = the AMI list. The newest AMI per architecture: the keep anchor, and
# the candidate for the next ami_ids pin.
newest_per_arch() {
  printf '%s\n' "$1" | jq -sr '[group_by(.arch)[] | max_by(.date).id] | join(" ")'
}

# in_list ITEM "a b c": ITEM is one of the space-separated words.
in_list() {
  case " $2 " in *" $1 "*) return 0 ;; esac
  return 1
}

# classify AMIS KEEP_NEWEST IN_USE: log the KEEP/DELETE verdict for every AMI
# (log writes to stderr) and emit the delete targets as "id<TAB>snaps" lines
# on stdout.
classify() {
  _classify_id="" _classify_date="" _classify_name="" _classify_snaps=""
  _classify_keep_newest="$2"
  _classify_in_use="$3"
  printf '%s\n' "$1" | jq -r '[.id, .date, .name, (.snaps | join(" "))] | @tsv' |
    while IFS="$TAB" read -r _classify_id _classify_date _classify_name _classify_snaps; do
      [ -n "$_classify_id" ] || continue
      if in_list "$_classify_id" "$_classify_keep_newest"; then
        log "KEEP   $_classify_id  $_classify_name  ($_classify_date)  [newest for its arch]"
      elif in_list "$_classify_id" "$_classify_in_use"; then
        log "KEEP   $_classify_id  $_classify_name  ($_classify_date)  [in use (instance or launch template)]"
      else
        log "DELETE $_classify_id  $_classify_name  ($_classify_date)  snapshots: $_classify_snaps"
        printf '%s\t%s\n' "$_classify_id" "$_classify_snaps"
      fi
    done
}

# $1 = "id<TAB>snaps" lines. Deregister each AMI, then delete its snapshots
# (deregistering first: a snapshot backing a registered AMI cannot be deleted).
delete_amis() {
  _delete_amis_id="" _delete_amis_snaps="" _delete_amis_snap=""
  printf '%s\n' "$1" | while IFS="$TAB" read -r _delete_amis_id _delete_amis_snaps; do
    [ -n "$_delete_amis_id" ] || continue
    log "Deregistering $_delete_amis_id..."
    aws ec2 deregister-image --region "$REGION" --image-id "$_delete_amis_id"
    for _delete_amis_snap in $_delete_amis_snaps; do
      log "  deleting snapshot $_delete_amis_snap..."
      aws ec2 delete-snapshot --region "$REGION" --snapshot-id "$_delete_amis_snap"
    done
  done
}

main() {
  _main_mode=""
  require aws jq
  init_region "$@"
  shift "$ROOT_SHIFT"
  case "${1:-}" in
  '') _main_mode=dry-run ;;
  --delete) _main_mode=delete ;;
  *) usage ;;
  esac
  [ "$#" -le 1 ] || usage

  _main_amis="$(list_base_amis)"
  if [ -z "$_main_amis" ]; then
    log "no available tag:Name=$AMI_TAG_NAME AMIs owned by this account in $REGION; nothing to do."
    return 0
  fi

  _main_in_use="$(list_in_use_amis)"
  # shellcheck disable=SC2086,SC2116 # unquoted echo collapses tabs/newlines to single spaces
  _main_in_use="$(echo $_main_in_use)"
  _main_doomed="$(classify "$_main_amis" "$(newest_per_arch "$_main_amis")" "$_main_in_use")"

  if [ -z "$_main_doomed" ]; then
    log "every AMI is a keeper; nothing to delete."
    return 0
  fi
  if [ "$_main_mode" = dry-run ]; then
    log "dry run: nothing was changed. Re-run with --delete to clean up."
    return 0
  fi

  confirm "Deregister the AMIs marked DELETE above and delete their backing snapshots?"
  delete_amis "$_main_doomed"
  log "done."
}

main "$@"
