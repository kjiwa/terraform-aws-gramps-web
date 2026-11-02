#!/bin/sh
# Tests for prune_images in build/app/bundle/scripts/common.sh: it prunes
# images after a healthy deploy and never fails the hook.
set -eu

TESTS_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly TESTS_DIR
readonly COMMON="$TESTS_DIR/../../build/app/bundle/scripts/common.sh"
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gramps-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
STUB_LOG="$WORK/calls.log"
export STUB_LOG

cat >"$WORK/bin/docker" <<'STUB'
#!/bin/sh
echo "docker $*" >>"$STUB_LOG"
[ -z "${STUB_DOCKER_FAIL:-}" ] || exit 1
STUB
chmod +x "$WORK/bin/docker"
PATH="$WORK/bin:$PATH"

# lib CODE: runs CODE in a fresh shell with common.sh loaded and log silenced.
lib() {
  : >"$STUB_LOG"
  sh -c ". '$COMMON'; log() { :; }; $1"
}

main() {
  lib 'prune_images'
  assert_eq "prunes every unused image" \
    "docker image prune --all --force" "$(cat "$STUB_LOG")"

  assert_status "a failing prune does not fail the hook" 0 \
    env STUB_DOCKER_FAIL=1 sh -c ". '$COMMON'; log() { :; }; prune_images"
  finish
}

main "$@"
