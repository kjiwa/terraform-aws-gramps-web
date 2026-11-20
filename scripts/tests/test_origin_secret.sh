#!/bin/sh
# Tests for the origin secret on the instance: after_install.sh renders the
# nginx map from the SSM parameter beside the frontend config, fails the
# deploy when it cannot, and validate_service.sh reads the app through the
# loopback listener. The function is cut out of after_install.sh (the script
# runs main on load); aws, curl and docker are stubs on PATH.
set -eu

TESTS_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly TESTS_DIR
readonly BUNDLE="$TESTS_DIR/../../build/app/bundle/scripts"
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gramps-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/compose"
STUB_LOG="$WORK/calls.log"
export STUB_LOG

# Public listener (https): the status depends on whether the secret header is
# sent. Loopback listener (http): STUB_HTTP.
cat >"$WORK/bin/curl" <<'STUB'
#!/bin/sh
for _arg in "$@"; do _url="$_arg"; done
case "$_url" in
https:*)
  case "$*" in
  *X-Origin-Verify*)
    echo "curl $*" >>"$STUB_LOG"
    printf '%s' "${STUB_PUBLIC_HDR:-200}"
    ;;
  *)
    echo "curl $_url" >>"$STUB_LOG"
    printf '%s' "${STUB_PUBLIC_NOHDR:-403}"
    ;;
  esac
  ;;
*)
  echo "curl $_url" >>"$STUB_LOG"
  printf '%s' "${STUB_HTTP:-200}"
  ;;
esac
STUB
# The proxy: `inspect` answers "<id> <status> <restarts>", from
# STUB_INSPECT_BEFORE on its first call and STUB_INSPECT_AFTER on later ones
# (default: a recreated, running proxy). STUB_PREFLIGHT_FAIL, STUB_TEST_FAIL and
# STUB_RELOAD_FAIL fail `docker run ... -t`, `exec ... nginx -t` and the reload.
cat >"$WORK/bin/docker" <<'STUB'
#!/bin/sh
echo "docker $*" >>"$STUB_LOG"
case "$*" in
"run "*)
  [ -z "${STUB_PREFLIGHT_FAIL:-}" ] || { echo "nginx: [emerg] bad config"; exit 1; }
  ;;
*"ps -q proxy"*) echo proxyid ;;
"inspect "*)
  if [ -f "$STUB_LOG.inspected" ]; then echo "${STUB_INSPECT_AFTER:-new running 0}"; else
    touch "$STUB_LOG.inspected"; echo "${STUB_INSPECT_BEFORE:-old running 0}"; fi
  ;;
*"logs --tail 30 proxy"*) echo "nginx: [emerg] boom" ;;
*"nginx -t"*) [ -z "${STUB_TEST_FAIL:-}" ] || exit 1 ;;
*"nginx -s reload"*) [ -z "${STUB_RELOAD_FAIL:-}" ] || exit 1 ;;
esac
STUB
chmod +x "$WORK/bin/"*
PATH="$WORK/bin:$PATH"

# render CODE: runs render_origin_secret with ssm_value and ssm_optional
# defined by CODE.
render() {
  _render_fn="$(awk '/^render_origin_secret\(\) \{/ { p = 1 } p { print } p && /^}/ { exit }' "$BUNDLE/after_install.sh")"
  sh -c "set -eu
log() { :; }
COMPOSE_DIR='$WORK/compose'
SSM_FRONTEND_CONFIG_PARAM=/gramps-web/prod/frontend-config
$1
$_render_fn
render_origin_secret"
}

# run_validate [VAR=value...]: runs validate_service.sh against the stubs, with
# the proxy's rendered files in the compose dir.
run_validate() {
  : >"$STUB_LOG"
  printf 'REGION=us-east-1\nCELERY_REGION=us-east-1\nSSM_RUNTIME_PARAM=/p/a\nSSM_FLASK_SECRET_PARAM=/p/b\nSSM_SMTP_PASSWORD_PARAM=/p/c\nSSM_FRONTEND_CONFIG_PARAM=/p/d\nGRAMPS_DATA_ROOT=/d\nCOMPOSE_DIR=%s\n' "$WORK/compose" >"$WORK/instance.env"
  _run_validate_script="$(validate_copy "$BUNDLE" "$WORK/validate" "http://localhost/" "https://localhost/" 1)"
  env "$@" INSTANCE_ENV="$WORK/instance.env" DEPLOY_LOG="$WORK/deploy.log" sh "$_run_validate_script" >/dev/null 2>&1 && echo "status 0" || echo "status 1"
}

# write_proxy_files MODE: the files after_install renders ("1" enforces).
write_proxy_files() {
  printf '"s3cret" 1;\n"older" 1;\ndefault 0;\n' >"$WORK/compose/origin-secret.map"
  printf 'default %s;\n' "$1" >"$WORK/compose/origin-enforce.map"
}

main() {
  # shellcheck disable=SC2016 # the stub bodies are code for the child shell
  render 'ssm_value() { [ "$1" = /gramps-web/prod/origin-secret ] && echo s3cret; }
ssm_optional() { :; }'
  assert_eq "current secret alone, no mode parameter: accepted, log mode" '"s3cret" 1;
default 0;' "$(cat "$WORK/compose/origin-secret.map")"
  assert_eq "no mode parameter means log, never enforce" "default 0;" "$(cat "$WORK/compose/origin-enforce.map")"
  assert_eq "the files are private to their owner" "600 600" \
    "$(for f in origin-secret.map origin-enforce.map; do stat -c %a "$WORK/compose/$f" 2>/dev/null || stat -f %Lp "$WORK/compose/$f"; done | tr '\n' ' ' | sed 's/ $//')"

  # shellcheck disable=SC2016
  render 'ssm_value() { echo s3cret; }
ssm_optional() { case "$1" in */origin-secret-extra) echo "older,oldest" ;; */origin-secret-mode) echo enforce ;; esac; }'
  assert_eq "extras are accepted beside the current secret" '"s3cret" 1;
"older" 1;
"oldest" 1;
default 0;' "$(cat "$WORK/compose/origin-secret.map")"
  assert_eq "mode enforce renders default 1" "default 1;" "$(cat "$WORK/compose/origin-enforce.map")"

  # shellcheck disable=SC2012 # the name is fixed
  _main_inode="$(ls -i "$WORK/compose/origin-secret.map" | cut -d' ' -f1)"
  # shellcheck disable=SC2016
  render 'ssm_value() { echo changed; }
ssm_optional() { :; }'
  # shellcheck disable=SC2012 # the name is fixed
  assert_eq "a re-render keeps the inode: the proxy's single-file bind mount follows it" "$_main_inode" \
    "$(ls -i "$WORK/compose/origin-secret.map" | cut -d' ' -f1)"

  rm -f "$WORK/compose/origin-secret.map"
  assert_status "a missing current secret fails the deploy" 1 render 'ssm_value() { return 1; }
ssm_optional() { :; }'
  assert_eq "and leaves no map behind" "no" "$([ -e "$WORK/compose/origin-secret.map" ] && echo yes || echo no)"

  write_proxy_files 1
  assert_eq "validate, enforce: no header 403, header served" "status 0" \
    "$(run_validate STUB_HTTP=200 STUB_PUBLIC_NOHDR=403 STUB_PUBLIC_HDR=200)"
  assert_eq "validate: it reads the app on http://localhost/" "1" "$(grep -c '^curl http://localhost/$' "$STUB_LOG")"
  assert_eq "validate: it sends the rendered current secret" "1" "$(grep -c '^curl .*X-Origin-Verify: s3cret' "$STUB_LOG")"
  assert_eq "validate, enforce: a request without the header that is not 403 fails" "status 1" \
    "$(run_validate STUB_HTTP=200 STUB_PUBLIC_NOHDR=200 STUB_PUBLIC_HDR=200)"
  assert_eq "validate, enforce: the secret being refused fails" "status 1" \
    "$(run_validate STUB_HTTP=200 STUB_PUBLIC_NOHDR=403 STUB_PUBLIC_HDR=403)"
  assert_eq "validate, enforce: TLS not answering fails" "status 1" \
    "$(run_validate STUB_HTTP=200 STUB_PUBLIC_NOHDR=000 STUB_PUBLIC_HDR=000)"
  assert_eq "validate: app down fails" "status 1" \
    "$(run_validate STUB_HTTP=502 STUB_PUBLIC_NOHDR=403 STUB_PUBLIC_HDR=200)"

  write_proxy_files 0
  assert_eq "validate, log mode: neither request may be 403" "status 0" \
    "$(run_validate STUB_HTTP=200 STUB_PUBLIC_NOHDR=200 STUB_PUBLIC_HDR=200)"
  assert_eq "validate, log mode: a 403 without the header fails" "status 1" \
    "$(run_validate STUB_HTTP=200 STUB_PUBLIC_NOHDR=403 STUB_PUBLIC_HDR=200)"

  assert_eq "the production validate script reads no URL or timeout from the environment" "0" \
    "$(grep -c 'VALIDATE_' "$BUNDLE/validate_service.sh" || true)"

  cp "$BUNDLE/../docker-compose.yml" "$WORK/compose/docker-compose.yml"
  # run_start [VAR=value...]: application_start.sh; prints its output and exit status.
  _compose="docker compose --env-file $WORK/compose/.env -f $WORK/compose/docker-compose.yml"
  run_start() {
    : >"$STUB_LOG"
    rm -f "$STUB_LOG.inspected"
    env PROXY_WAIT_SECONDS=1 "$@" INSTANCE_ENV="$WORK/instance.env" DEPLOY_LOG="$WORK/deploy.log" \
      sh "$BUNDLE/application_start.sh" 2>&1 && echo "status 0" || echo "status 1"
  }
  last_line() { printf '%s\n' "$1" | tail -n 1; }
  has_line() { printf '%s\n' "$1" | grep -c -e "$2" || true; }
  _mounts="-v $WORK/compose/nginx.conf:/etc/nginx/conf.d/default.conf:ro -v $WORK/compose/origin-secret.map:/etc/nginx/origin-secret.map:ro -v $WORK/compose/origin-enforce.map:/etc/nginx/origin-enforce.map:ro -v /etc/gramps/tls:/etc/gramps/tls:ro"

  _start_out="$(run_start A=1)"
  assert_eq "application_start: check the config in a throwaway container, up, wait, test, reload" \
    "docker run --rm --entrypoint nginx $_mounts docker.io/library/nginx:1.30-alpine -t
$_compose ps -q proxy
docker inspect -f {{.Id}} {{.State.Status}} {{.RestartCount}} proxyid
$_compose up -d --remove-orphans
$_compose ps -q proxy
docker inspect -f {{.Id}} {{.State.Status}} {{.RestartCount}} proxyid
$_compose ps -q proxy
docker inspect -f {{.Id}} {{.State.Status}} {{.RestartCount}} proxyid
$_compose exec -T proxy nginx -t
$_compose exec -T proxy nginx -s reload" \
    "$(cat "$STUB_LOG")"
  assert_eq "application_start succeeds" "status 0" "$(last_line "$_start_out")"

  _start_out="$(run_start STUB_PREFLIGHT_FAIL=1)"
  assert_eq "a config nginx rejects fails before the running proxy is touched" "status 1" "$(last_line "$_start_out")"
  assert_eq "the pre-flight error is in the output" "1" "$(has_line "$_start_out" 'nginx: \[emerg\] bad config')"
  assert_eq "no compose command ran after the failed pre-flight" "0" "$(grep -c 'docker compose' "$STUB_LOG" || true)"

  _start_out="$(run_start STUB_INSPECT_BEFORE='same running 2' STUB_INSPECT_AFTER='same running 2')"
  assert_eq "a healthy proxy with a historical restart count deploys" "status 0" "$(last_line "$_start_out")"
  assert_eq "a proxy that was not recreated is checked once, not waited on" "2" "$(grep -c 'inspect' "$STUB_LOG")"

  _start_out="$(run_start STUB_INSPECT_BEFORE='old running 2' STUB_INSPECT_AFTER='new running 0')"
  assert_eq "a recreated proxy starts counting from zero" "status 0" "$(last_line "$_start_out")"

  _start_out="$(run_start STUB_INSPECT_BEFORE='same running 2' STUB_INSPECT_AFTER='same running 3')"
  assert_eq "a restart during the deploy fails it" "status 1" "$(last_line "$_start_out")"
  assert_eq "with the proxy's last log lines" "1" "$(has_line "$_start_out" 'nginx: \[emerg\] boom')"

  _start_out="$(run_start STUB_INSPECT_AFTER='new restarting 4')"
  assert_eq "a crash-looping new proxy fails the deploy" "status 1" "$(last_line "$_start_out")"
  assert_eq "with the proxy's last log lines" "1" "$(has_line "$_start_out" 'nginx: \[emerg\] boom')"

  _start_out="$(run_start STUB_TEST_FAIL=1)"
  assert_eq "a config the running proxy rejects (nginx -t) fails before the reload" "status 1" "$(last_line "$_start_out")"
  assert_eq "and the reload never ran" "0" "$(grep -c 'nginx -s reload' "$STUB_LOG" || true)"

  _start_out="$(run_start STUB_RELOAD_FAIL=1)"
  assert_eq "a failed reload fails the deploy with the proxy's log lines" "1 status 1" \
    "$(has_line "$_start_out" 'nginx: \[emerg\] boom') $(last_line "$_start_out")"

  _start_out="$(run_start PROXY_WAIT_SECONDS=abc)"
  assert_eq "a non-numeric PROXY_WAIT_SECONDS fails loudly, before any docker call" "status 1 0" \
    "$(last_line "$_start_out") $(grep -c docker "$STUB_LOG" || true)"
  finish
}

main "$@"
