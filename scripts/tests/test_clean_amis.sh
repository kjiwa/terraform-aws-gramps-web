#!/bin/sh
# Tests for scripts/clean-amis.sh: which base AMIs it keeps and deletes, and
# that a failed lookup aborts before anything is deleted. A stub aws serves
# fixtures that model the EC2 calls the script makes.
set -eu

TESTS_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly TESTS_DIR
readonly CLEAN="$TESTS_DIR/../clean-amis.sh"
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gramps-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
STUB_LOG="$WORK/calls.log"
export STUB_LOG

# Fixtures: one launch template whose default is v1, latest v3, and which also
# has v2; a running instance on ami-new-arm.
cat >"$WORK/images.json" <<'JSON'
[
  {"id":"ami-old-arm","name":"gramps-web-base-arm64-1","arch":"arm64","date":"2026-01-01T00:00:00.000Z","snaps":["snap-old-arm"]},
  {"id":"ami-mid-arm","name":"gramps-web-base-arm64-2","arch":"arm64","date":"2026-02-01T00:00:00.000Z","snaps":["snap-mid-arm"]},
  {"id":"ami-new-arm","name":"gramps-web-base-arm64-3","arch":"arm64","date":"2026-03-01T00:00:00.000Z","snaps":["snap-new-arm"]},
  {"id":"ami-old-x86","name":"gramps-web-base-x86-1","arch":"x86_64","date":"2026-01-02T00:00:00.000Z","snaps":["snap-old-x86"]},
  {"id":"ami-new-x86","name":"gramps-web-base-x86-3","arch":"x86_64","date":"2026-03-02T00:00:00.000Z","snaps":["snap-new-x86"]}
]
JSON

cat >"$WORK/bin/aws" <<'STUB'
#!/bin/sh
echo "aws $*" >>"$STUB_LOG"
case "$2" in
describe-images) cat "$STUB_DIR/images.json" ;;
describe-instances) echo "ami-new-arm" ;;
describe-launch-templates) echo "lt-1" ;;
describe-launch-template-versions)
  [ -z "${STUB_LT_FAIL:-}" ] || exit 1
  case "$*" in
  *--versions*) echo "ami-new-arm ami-old-arm" ;; # $Latest and $Default only
  *) echo "ami-new-arm ami-mid-arm ami-old-arm ami-new-x86" ;;
  esac
  ;;
esac
STUB
chmod +x "$WORK/bin/aws"
STUB_DIR="$WORK"
export STUB_DIR
PATH="$WORK/bin:$PATH"

# run_clean ARGS...: runs the script and prints its stderr then the mutating calls.
run_clean() {
  : >"$STUB_LOG"
  AWS_REGION=us-east-1 FORCE=1 sh "$CLEAN" "$@" 2>&1 || echo "exit $?"
  grep -E 'deregister-image|delete-snapshot' "$STUB_LOG" || true
}

main() {
  _main_dry="$(run_clean)"
  assert_eq "newest per arch is kept" "1" "$(printf '%s\n' "$_main_dry" | grep -c 'KEEP   ami-new-arm .*newest')"
  assert_eq "an AMI in an older launch template version is kept" "1" \
    "$(printf '%s\n' "$_main_dry" | grep -c 'KEEP   ami-mid-arm')"
  assert_eq "the default version's AMI is kept" "1" "$(printf '%s\n' "$_main_dry" | grep -c 'KEEP   ami-old-arm')"
  assert_eq "an unreferenced old AMI is marked for deletion" "1" \
    "$(printf '%s\n' "$_main_dry" | grep -c 'DELETE ami-old-x86')"
  assert_eq "a dry run deletes nothing" "0" "$(grep -cE 'deregister-image|delete-snapshot' "$STUB_LOG")"

  _main_del="$(run_clean --delete)"
  assert_eq "delete deregisters then deletes the snapshot, only for the unreferenced AMI" \
    "aws ec2 deregister-image --region us-east-1 --image-id ami-old-x86
aws ec2 delete-snapshot --region us-east-1 --snapshot-id snap-old-x86" \
    "$(printf '%s\n' "$_main_del" | grep -E '^aws ')"

  : >"$STUB_LOG"
  assert_status "a failed launch template lookup fails the run" 1 \
    env STUB_LT_FAIL=1 AWS_REGION=us-east-1 FORCE=1 sh "$CLEAN" --delete
  assert_eq "a failed lookup deletes nothing" "0" "$(grep -cE 'deregister-image|delete-snapshot' "$STUB_LOG")"

  printf '[]\n' >"$WORK/images.json"
  assert_eq "no AMIs: nothing to do" "1" "$(run_clean --delete | grep -c 'nothing to do')"
  finish
}

main "$@"
