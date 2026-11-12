#!/bin/sh
# Tests for build/ami/rightsize-watchdog.sh: it drains and replaces only when
# every input the replacement needs is present and the shared check says
# replace. The runtime library and instance.env are fixtures; docker, sync and
# keel-rightsize-check are stubs on PATH.
set -eu

TESTS_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly TESTS_DIR
readonly WATCHDOG="$TESTS_DIR/../../build/ami/rightsize-watchdog.sh"
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gramps-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
STUB_LOG="$WORK/calls.log"
export STUB_LOG

for _stub in docker sync keel-rightsize-check; do
  cat >"$WORK/bin/$_stub" <<'STUB'
#!/bin/sh
echo "$(basename "$0")${*:+ $*}" >>"$STUB_LOG"
[ "$(basename "$0")" != keel-rightsize-check ] || exit "${STUB_CHECK_EXIT:-0}"
STUB
  chmod +x "$WORK/bin/$_stub"
done
PATH="$WORK/bin:$PATH"

cat >"$WORK/runtime.sh" <<'LIB'
load_runtime_env() { :; }
detach_data_volume() { echo "detach_data_volume" >>"$STUB_LOG"; }
set_unhealthy() { echo "set_unhealthy $*" >>"$STUB_LOG"; }
LIB
GRAMPS_RUNTIME_LIB="$WORK/runtime.sh"
export GRAMPS_RUNTIME_LIB

# run_watchdog CHECK_EXIT ENV_LINES...: writes ENV_LINES as instance.env, runs
# the watchdog and prints the stub call log.
run_watchdog() {
  _run_check="$1"
  shift
  : >"$STUB_LOG"
  printf '%s\n' "$@" >"$WORK/instance.env"
  INSTANCE_ENV="$WORK/instance.env" STUB_CHECK_EXIT="$_run_check" sh "$WATCHDOG" >/dev/null 2>&1
  cat "$STUB_LOG"
}

main() {
  _main_full='REGION=us-east-1 LAST_RIGHTSIZE_PARAM=/gramps-web/prod/last-rightsize COMPOSE_DIR=/opt/gramps'

  assert_eq "check replace: drain, detach, then mark unhealthy" \
    "keel-rightsize-check us-east-1 gramps-web 3
docker compose --env-file /opt/gramps/.env -f /opt/gramps/docker-compose.yml stop -t 30 grampsweb_celery grampsweb
sync
detach_data_volume
set_unhealthy /gramps-web/prod/last-rightsize" \
    "$(run_watchdog 0 "$(echo "$_main_full" | tr ' ' '\n')")"

  assert_eq "check stay: nothing is touched after the check" \
    "keel-rightsize-check us-east-1 gramps-web 3" \
    "$(run_watchdog 1 "$(echo "$_main_full" | tr ' ' '\n')")"

  assert_eq "check error: same as stay" \
    "keel-rightsize-check us-east-1 gramps-web 3" \
    "$(run_watchdog 2 "$(echo "$_main_full" | tr ' ' '\n')")"

  assert_eq "check error is logged" \
    "[rightsize-watchdog] keel-rightsize-check exited 2; staying." \
    "$(INSTANCE_ENV="$WORK/instance.env" STUB_CHECK_EXIT=2 sh "$WATCHDOG" 2>&1)"

  assert_eq "missing LAST_RIGHTSIZE_PARAM: no check, drain, detach or health call" \
    "" \
    "$(run_watchdog 0 REGION=us-east-1 COMPOSE_DIR=/opt/gramps)"

  assert_eq "missing COMPOSE_DIR: no check, drain, detach or health call" \
    "" \
    "$(run_watchdog 0 REGION=us-east-1 LAST_RIGHTSIZE_PARAM=/p)"

  assert_eq "missing REGION: no check, drain, detach or health call" \
    "" \
    "$(run_watchdog 0 LAST_RIGHTSIZE_PARAM=/p COMPOSE_DIR=/opt/gramps)"

  assert_eq "RIGHTSIZE_MIN_UPTIME_HOURS reaches the check" \
    "keel-rightsize-check us-east-1 gramps-web 6" \
    "$(run_watchdog 1 REGION=us-east-1 LAST_RIGHTSIZE_PARAM=/p COMPOSE_DIR=/c RIGHTSIZE_MIN_UPTIME_HOURS=6)"

  assert_status "missing instance.env exits 0" 0 \
    env INSTANCE_ENV="$WORK/absent.env" sh "$WATCHDOG"
  finish
}

main "$@"
