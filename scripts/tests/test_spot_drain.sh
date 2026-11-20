#!/bin/sh
# Tests for build/ami/spot-drain.sh: the Spot notice drain and the ExecStop
# drain for ASG terminations, and that the two never both run. The runtime
# library, instance.env and the drain claim are fixtures; docker, sync, curl
# and sleep are stubs on PATH.
set -eu

TESTS_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly TESTS_DIR
readonly DRAIN="$TESTS_DIR/../../build/ami/spot-drain.sh"
readonly RUNTIME="$TESTS_DIR/../../build/ami/gramps-runtime.sh"
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gramps-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
STUB_LOG="$WORK/calls.log"
export STUB_LOG

for _stub in docker sync; do
  cat >"$WORK/bin/$_stub" <<'STUB'
#!/bin/sh
echo "$(basename "$0")${*:+ $*}" >>"$STUB_LOG"
STUB
done
# The poller sleeps between IMDS reads; the stub ends the loop after a few.
cat >"$WORK/bin/sleep" <<'STUB'
#!/bin/sh
_n="$(cat "$STUB_LOG.sleeps" 2>/dev/null || echo 0)"
echo $((_n + 1)) >"$STUB_LOG.sleeps"
[ "$_n" -lt 3 ] || exit 1
STUB
cat >"$WORK/bin/curl" <<'STUB'
#!/bin/sh
printf '%s' "${STUB_SPOT_CODE:-404}"
STUB
cat >"$WORK/bin/aws" <<'STUB'
#!/bin/sh
[ -z "${STUB_ASG_FAIL:-}" ] || exit 1
echo "${STUB_ASG_STATE:-InService}"
STUB
chmod +x "$WORK/bin/"*
PATH="$WORK/bin:$PATH"

cat >"$WORK/runtime.sh" <<'LIB'
IMDS=http://imds.invalid
imds_token() { echo token; }
instance_terminating() { [ "${STUB_TERMINATING:-0}" = 1 ]; }
detach_data_volume() { echo "detach_data_volume" >>"$STUB_LOG"; }
set_unhealthy() { echo "set_unhealthy${1:+ $1}" >>"$STUB_LOG"; }
LIB
GRAMPS_RUNTIME_LIB="$WORK/runtime.sh"
export GRAMPS_RUNTIME_LIB
printf 'COMPOSE_DIR=/opt/gramps\n' >"$WORK/instance.env"

# run_drain [VAR=value...] -- ARGS: fresh claim, prints the stub call log.
run_drain() {
  : >"$STUB_LOG"
  rm -rf "$WORK/claim" "$STUB_LOG.sleeps"
  _run_env=""
  while [ "$1" != "--" ]; do
    _run_env="$_run_env $1"
    shift
  done
  shift
  # shellcheck disable=SC2086
  env INSTANCE_ENV="$WORK/instance.env" DRAIN_CLAIM="$WORK/claim" DRAIN_WAIT_SECONDS=0 $_run_env \
    sh "$DRAIN" "$@" >/dev/null 2>&1 || true
  cat "$STUB_LOG"
}

readonly STOP_CMD="docker compose --env-file /opt/gramps/.env -f /opt/gramps/docker-compose.yml stop -t"

main() {
  assert_eq "spot notice: stop writers (30s grace), sync, detach, mark unhealthy" \
    "$STOP_CMD 30 grampsweb_celery grampsweb
sync
detach_data_volume
set_unhealthy" \
    "$(run_drain STUB_SPOT_CODE=200 --)"

  assert_eq "no notice: nothing is touched" "" "$(run_drain STUB_SPOT_CODE=404 --)"

  assert_eq "ASG termination: stop writers (20s grace), sync, detach, no unhealthy mark" \
    "$STOP_CMD 20 grampsweb_celery grampsweb
sync
detach_data_volume" \
    "$(run_drain STUB_TERMINATING=1 -- stop)"

  assert_eq "stop on an instance that is not terminating (reboot): nothing is touched" "" \
    "$(run_drain STUB_TERMINATING=0 -- stop)"

  : >"$STUB_LOG"
  mkdir -p "$WORK/claim"
  touch "$WORK/claim/done"
  STUB_TERMINATING=1 DRAIN_CLAIM="$WORK/claim" DRAIN_WAIT_SECONDS=0 INSTANCE_ENV="$WORK/instance.env" sh "$DRAIN" stop >/dev/null 2>&1 || true
  assert_eq "stop after the spot drain already ran: nothing is repeated" "" "$(cat "$STUB_LOG")"

  printf 'REGION=us-east-1\n' >"$WORK/instance.env"
  assert_eq "no COMPOSE_DIR: nothing to stop, still detaches" \
    "sync
detach_data_volume" \
    "$(run_drain STUB_TERMINATING=1 -- stop)"
  printf 'COMPOSE_DIR=/opt/gramps\n' >"$WORK/instance.env"

  for _main_state in Terminating Terminating:Wait; do
    assert_status "ASG state $_main_state counts as terminating" 0 \
      env STUB_ASG_STATE="$_main_state" sh -c ". '$RUNTIME'; REGION=us-east-1; instance_terminating"
  done
  assert_status "ASG state InService is not terminating" 1 \
    env STUB_ASG_STATE=InService sh -c ". '$RUNTIME'; REGION=us-east-1; instance_terminating"
  assert_status "a failed ASG lookup is not terminating" 1 \
    env STUB_ASG_FAIL=1 sh -c ". '$RUNTIME'; REGION=us-east-1; instance_terminating"

  assert_status "an unknown argument is a usage error" 2 \
    env GRAMPS_RUNTIME_LIB="$WORK/runtime.sh" sh "$DRAIN" bogus
  finish
}

main "$@"
