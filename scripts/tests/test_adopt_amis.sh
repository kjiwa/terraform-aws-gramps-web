#!/bin/sh
# Tests for scripts/adopt-amis.sh: when it writes launch template versions,
# repins the group, starts a refresh and prunes old versions. A stub aws logs
# every call and serves canned EC2 and Auto Scaling responses.
set -eu

TESTS_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly TESTS_DIR
readonly ADOPT="$TESTS_DIR/../adopt-amis.sh"
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gramps-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
STUB_LOG="$WORK/calls.log"
STUB_DIR="$WORK/fixtures"
export STUB_LOG STUB_DIR
mkdir -p "$STUB_DIR"

NOW="$(jq -n '"2026-11-19T00:00:00Z" | fromdateiso8601')"
readonly NOW
readonly LTS='{"arm64":"lt-arm","x86_64":"lt-x86"}'
readonly ALARMS='["gramps-web-instance-refresh-pathological"]'

cat >"$WORK/bin/aws" <<'STUB'
#!/bin/sh
echo "aws $*" >>"$STUB_LOG"
_cmd="$2"
_lt=""
_prev=""
for _arg in "$@"; do
  [ "$_prev" != --launch-template-id ] || _lt="$_arg"
  _prev="$_arg"
done
case "$_cmd" in
describe-launch-template-versions)
  case "$*" in
  *--versions*) cat "$STUB_DIR/ltv-$_lt-latest.json" ;;
  *) cat "$STUB_DIR/ltv-$_lt-all.json" ;;
  esac
  ;;
create-launch-template-version) cat "$STUB_DIR/create-$_lt.json" ;;
*) [ ! -f "$STUB_DIR/$_cmd.json" ] || cat "$STUB_DIR/$_cmd.json" ;;
esac
STUB
chmod +x "$WORK/bin/aws"
PATH="$WORK/bin:$PATH"

# Both templates are on v3 with the old AMI; the newest AMIs are 1 day old; one
# instance runs the old arm64 AMI (49 days old).
reset_fixtures() {
  rm -f "$STUB_DIR"/*
  cat >"$STUB_DIR/describe-images.json" <<'JSON'
{"Images":[
  {"ImageId":"ami-arm-new","Architecture":"arm64","CreationDate":"2026-11-18T10:00:00.000Z"},
  {"ImageId":"ami-arm-old","Architecture":"arm64","CreationDate":"2026-10-01T10:00:00.000Z"},
  {"ImageId":"ami-x86-new","Architecture":"x86_64","CreationDate":"2026-11-18T10:05:00.000Z"},
  {"ImageId":"ami-x86-old","Architecture":"x86_64","CreationDate":"2026-10-01T10:05:00.000Z"}
]}
JSON
  for _arch in arm x86; do
    printf '{"LaunchTemplateVersions":[{"VersionNumber":3,"DefaultVersion":false,"LaunchTemplateData":{"ImageId":"ami-%s-old"}}]}\n' "$_arch" >"$STUB_DIR/ltv-lt-$_arch-latest.json"
    printf '{"LaunchTemplateVersion":{"VersionNumber":4}}\n' >"$STUB_DIR/create-lt-$_arch.json"
    printf '{"LaunchTemplateVersions":[{"VersionNumber":3,"DefaultVersion":false},{"VersionNumber":1,"DefaultVersion":true}]}\n' >"$STUB_DIR/ltv-lt-$_arch-all.json"
  done
  write_group 3 3
  cat >"$STUB_DIR/describe-instances.json" <<'JSON'
{"Reservations":[{"Instances":[{"InstanceId":"i-1","ImageId":"ami-arm-old"}]}]}
JSON
  printf '{"InstanceRefreshes":[{"Status":"Successful"}]}\n' >"$STUB_DIR/describe-instance-refreshes.json"
  printf '{"MetricAlarms":[{"AlarmName":"gramps-web-instance-refresh-pathological","StateValue":"OK"}]}\n' >"$STUB_DIR/describe-alarms.json"
  printf '{"InstanceRefreshId":"refresh-1"}\n' >"$STUB_DIR/start-instance-refresh.json"
}

# write_group ARM_VERSION X86_VERSION: the group's base spec and overrides.
write_group() {
  cat >"$STUB_DIR/describe-auto-scaling-groups.json" <<JSON
{"AutoScalingGroups":[{"AutoScalingGroupName":"gramps-web",
  "Instances":[{"InstanceId":"i-1","LifecycleState":"InService"},{"InstanceId":"i-2","LifecycleState":"Terminating"}],
  "MixedInstancesPolicy":{
    "LaunchTemplate":{
      "LaunchTemplateSpecification":{"LaunchTemplateId":"lt-arm","LaunchTemplateName":"gramps-web-1","Version":"$1"},
      "Overrides":[
        {"InstanceRequirements":{"VCpuCount":{"Min":2}},"LaunchTemplateSpecification":{"LaunchTemplateId":"lt-arm","LaunchTemplateName":"gramps-web-1","Version":"$1"}},
        {"InstanceRequirements":{"VCpuCount":{"Min":2}},"LaunchTemplateSpecification":{"LaunchTemplateId":"lt-x86","LaunchTemplateName":"gramps-web-2","Version":"$2"}}]},
    "InstancesDistribution":{"SpotAllocationStrategy":"price-capacity-optimized"}}}]}
JSON
}

# run_adopt [VAR=value...]: runs the script; prints its exit code line when it fails.
run_adopt() {
  : >"$STUB_LOG"
  env REGION=us-east-1 ADOPT_AMIS=true ASG_NAME=gramps-web LAUNCH_TEMPLATE_IDS="$LTS" \
    REFRESH_ALARM_NAMES="$ALARMS" AMI_MAX_AGE_DAYS=14 NOW="$NOW" "$@" sh "$ADOPT" >"$WORK/out.log" 2>&1 ||
    echo "exit $?"
}

calls() {
  grep -cE -e "$1" "$STUB_LOG" || true
}

main() {
  reset_fixtures
  assert_eq "adoption on: exits 0" "" "$(run_adopt)"
  assert_eq "a version per template from its latest, ImageId only, no description" "2" \
    "$(calls 'create-launch-template-version .*--source-version 3 --launch-template-data \{"ImageId":"ami-(arm|x86)-new"\} --output json$')"
  assert_eq "the group is repinned once, to numeric versions, by id" "1" "$(calls 'update-auto-scaling-group')"
  assert_eq "the repin carries no template name" "0" "$(grep 'update-auto-scaling-group' "$STUB_LOG" | grep -c LaunchTemplateName)"
  assert_eq "the repin keeps the instance requirements and distribution" "1" \
    "$(grep 'update-auto-scaling-group' "$STUB_LOG" | grep -c 'InstancesDistribution.*SpotAllocationStrategy\|VCpuCount')"
  assert_eq "the repin pins both templates to 4" "3" "$(grep 'update-auto-scaling-group' "$STUB_LOG" | grep -o '"Version": *"4"' | wc -l | tr -d ' ')"
  assert_eq "an over-age running AMI starts one refresh with the alarm and no healthy minimum" "1" \
    "$(calls 'start-instance-refresh .*MinHealthyPercentage.*0.*gramps-web-instance-refresh-pathological')"
  assert_eq "the running AMI age is published" "1" "$(calls 'put-metric-data .*AmiAgeDays.*Value=48.58,')"

  reset_fixtures
  sed -i.bak 's/2026-10-01T10:00:00/2026-11-14T10:00:00/' "$STUB_DIR/describe-images.json"
  run_adopt >/dev/null
  assert_eq "a running AMI under the age limit starts no refresh" "0" "$(calls 'start-instance-refresh')"
  assert_eq "but the new versions are still written" "2" "$(calls 'create-launch-template-version')"

  reset_fixtures
  for _arch in arm x86; do
    printf '{"LaunchTemplateVersions":[{"VersionNumber":3,"DefaultVersion":false,"LaunchTemplateData":{"ImageId":"ami-%s-new"}}]}\n' "$_arch" >"$STUB_DIR/ltv-lt-$_arch-latest.json"
  done
  run_adopt >/dev/null
  assert_eq "templates already on the newest AMI: no new version" "0" "$(calls 'create-launch-template-version')"
  assert_eq "templates already on the newest AMI: no repin" "0" "$(calls 'update-auto-scaling-group')"
  assert_eq "an old running AMI is still refreshed" "1" "$(calls 'start-instance-refresh')"

  reset_fixtures
  write_group 2 3
  run_adopt >/dev/null
  assert_eq "arm64 pinned behind its latest: both versions are still written" "2" "$(calls 'create-launch-template-version')"
  assert_eq "the unheld x86_64 template is repinned alone" "1" "$(calls 'update-auto-scaling-group')"
  assert_eq "the held arm64 pin stays at 2" "1" "$(grep 'update-auto-scaling-group' "$STUB_LOG" | grep -c '"LaunchTemplateId":"lt-arm","Version":"2"')"
  assert_eq "x86_64 moves to 4" "1" "$(grep 'update-auto-scaling-group' "$STUB_LOG" | grep -c '"LaunchTemplateId":"lt-x86","Version":"4"')"
  assert_eq "an old running AMI of the held arch starts no refresh" "0" "$(calls 'start-instance-refresh')"
  assert_eq "the hold is logged loudly" "1" "$(grep -c 'HELD' "$WORK/out.log")"
  assert_eq "the hold is published as a metric" "1" "$(calls 'put-metric-data .*AmiAdoptionHeld.*Value=1')"

  reset_fixtures
  write_group 3 2
  run_adopt >/dev/null
  assert_eq "x86_64 held, arm64 not: arm64 is repinned" "1" "$(grep 'update-auto-scaling-group' "$STUB_LOG" | grep -c '"LaunchTemplateId":"lt-arm","Version":"4"')"
  assert_eq "an old running AMI of the unheld arch still starts a refresh" "1" "$(calls 'start-instance-refresh')"

  reset_fixtures
  run_adopt >/dev/null
  assert_eq "nothing held: the metric is 0" "1" "$(calls 'put-metric-data .*AmiAdoptionHeld.*Value=0')"

  for _pin in '$Latest' '$Default' 'null'; do
    reset_fixtures
    write_group "$_pin" "$_pin"
    assert_eq "a non-numeric pin ($_pin) does not break the run" "" "$(run_adopt)"
    assert_eq "a non-numeric pin ($_pin) holds the group" "0" "$(calls 'update-auto-scaling-group')"
  done

  reset_fixtures
  printf '{"InstanceRefreshes":[{"Status":"InProgress"}]}\n' >"$STUB_DIR/describe-instance-refreshes.json"
  run_adopt >/dev/null
  assert_eq "a refresh in progress blocks every write" "0" "$(calls 'create-launch-template-version|update-auto-scaling-group|start-instance-refresh')"

  reset_fixtures
  printf '{"MetricAlarms":[{"AlarmName":"gramps-web-instance-refresh-pathological","StateValue":"ALARM"}]}\n' >"$STUB_DIR/describe-alarms.json"
  run_adopt >/dev/null
  assert_eq "an alarm in ALARM blocks every write" "0" "$(calls 'create-launch-template-version|update-auto-scaling-group|start-instance-refresh')"

  reset_fixtures
  jq -c 'del(.Images[] | select(.Architecture == "x86_64"))' "$STUB_DIR/describe-images.json" >"$STUB_DIR/i.json"
  mv "$STUB_DIR/i.json" "$STUB_DIR/describe-images.json"
  assert_eq "an architecture with no AMI fails the run" "exit 1" "$(run_adopt)"
  assert_eq "and writes nothing" "0" "$(calls 'create-launch-template-version|update-auto-scaling-group|start-instance-refresh')"

  reset_fixtures
  assert_eq "adoption off exits 0" "" "$(run_adopt ADOPT_AMIS=false)"
  assert_eq "adoption off makes no call" "0" "$(wc -l <"$STUB_LOG" | tr -d ' ')"

  reset_fixtures
  printf '{"LaunchTemplateVersions":[{"VersionNumber":1,"DefaultVersion":true},{"VersionNumber":2,"DefaultVersion":false},{"VersionNumber":3,"DefaultVersion":false},{"VersionNumber":4,"DefaultVersion":false},{"VersionNumber":5,"DefaultVersion":false},{"VersionNumber":6,"DefaultVersion":false},{"VersionNumber":7,"DefaultVersion":false},{"VersionNumber":8,"DefaultVersion":false}]}\n' >"$STUB_DIR/ltv-lt-arm-all.json"
  run_adopt >/dev/null
  assert_eq "versions beyond the newest five, except the default, are deleted" "1" \
    "$(calls 'delete-launch-template-versions --region us-east-1 --launch-template-id lt-arm --versions 2 3$')"
  finish
}

main "$@"
