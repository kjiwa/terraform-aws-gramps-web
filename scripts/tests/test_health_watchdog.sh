#!/bin/sh
# Tests for build/ami/health-watchdog.sh: the failure count, the threshold that
# marks the instance Unhealthy, and the metrics gate. The runtime library,
# instance.env and the count file are fixtures; curl and aws are stubs on PATH.
set -eu

TESTS_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly TESTS_DIR
readonly WATCHDOG="$TESTS_DIR/../../build/ami/health-watchdog.sh"
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gramps-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
STUB_LOG="$WORK/calls.log"
export STUB_LOG

# curl answers per URL: STUB_HTTPS and STUB_HTTP are the status codes.
cat >"$WORK/bin/curl" <<'STUB'
#!/bin/sh
for _arg in "$@"; do _url="$_arg"; done
echo "curl $_url" >>"$STUB_LOG"
case "$_url" in
https:*) printf '%s' "${STUB_HTTPS:-200}" ;;
*) printf '%s' "${STUB_HTTP:-200}" ;;
esac
STUB
cat >"$WORK/bin/aws" <<'STUB'
#!/bin/sh
echo "aws $*" >>"$STUB_LOG"
STUB
# /proc/meminfo exists only on Linux.
printf '#!/bin/sh\necho 50.0\n' >"$WORK/bin/awk"
# GNU df prints a header and one value line; the BSD df of a workstation lacks --output.
cat >"$WORK/bin/df" <<'STUB'
#!/bin/sh
printf 'Use%%\n 42%%\n'
STUB
chmod +x "$WORK/bin/"*
PATH="$WORK/bin:$PATH"

cat >"$WORK/runtime.sh" <<'LIB'
load_runtime_env() { :; }
set_unhealthy() { echo "set_unhealthy $*" >>"$STUB_LOG"; }
LIB
GRAMPS_RUNTIME_LIB="$WORK/runtime.sh"
COUNT_FILE="$WORK/failcount"
METRICS_STAMP="$WORK/stamp"
export GRAMPS_RUNTIME_LIB COUNT_FILE METRICS_STAMP

# run_watchdog COUNT ENV_LINES...: COUNT is the failure count already on disk
# ("" for none). Prints the calls other than curl, then the count left on disk.
run_watchdog() {
  _run_count="$1"
  shift
  : >"$STUB_LOG"
  rm -f "$COUNT_FILE" "$METRICS_STAMP"
  [ -z "$_run_count" ] || echo "$_run_count" >"$COUNT_FILE"
  printf '%s\n' "$@" >"$WORK/instance.env"
  INSTANCE_ENV="$WORK/instance.env" sh "$WATCHDOG" >/dev/null 2>&1 || true
  grep -v '^curl' "$STUB_LOG" || true
  echo "count=$(cat "$COUNT_FILE" 2>/dev/null || echo none)"
}

main() {
  _main_env='LAST_HEALTH_WATCHDOG_PARAM=/gramps-web/prod/last-health'

  assert_eq "healthy: the count is cleared" "count=none" "$(run_watchdog 4 "$_main_env")"
  assert_eq "a 3xx counts as healthy" "count=none" "$(STUB_HTTPS=302 run_watchdog 4 "$_main_env")"
  assert_eq "https down, http up: healthy" "count=none" "$(STUB_HTTPS=000 STUB_HTTP=200 run_watchdog 4 "$_main_env")"
  assert_eq "https 403 (origin secret enforced), loopback http up: healthy" "count=none" "$(STUB_HTTPS=403 STUB_HTTP=200 run_watchdog 4 "$_main_env")"
  assert_eq "a 403 is a failure, not health" "count=1" "$(STUB_HTTPS=403 STUB_HTTP=403 run_watchdog '' "$_main_env")"
  assert_eq "a failure increments the count" "count=5" "$(STUB_HTTPS=500 STUB_HTTP=500 run_watchdog 4 "$_main_env")"
  assert_eq "the tenth failure marks the instance unhealthy with the marker, then clears the count" \
    "set_unhealthy /gramps-web/prod/last-health
count=none" \
    "$(STUB_HTTPS=500 STUB_HTTP=500 run_watchdog 9 "$_main_env")"
  assert_eq "no instance.env: not counted" "" \
    "$(: >"$STUB_LOG"; INSTANCE_ENV="$WORK/absent.env" sh "$WATCHDOG" >/dev/null 2>&1; cat "$STUB_LOG")"
  assert_eq "metrics off: nothing is published" "" \
    "$(run_watchdog '' "$_main_env" | grep put-metric-data || true)"
  assert_eq "metrics on: one put-metric-data with the disk and memory series" "1" \
    "$(run_watchdog '' "$_main_env" STATUS_HOST_METRICS=true GRAMPS_DATA_ROOT=/ REGION=us-east-1 | grep -c 'put-metric-data.*DiskUsedPercent.*MemUsedPercent')"
  finish
}

main "$@"
