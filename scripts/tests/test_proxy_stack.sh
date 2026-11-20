#!/bin/sh
# Brings the real build/app/bundle/docker-compose.yml up in Docker, the way
# CodeDeploy does on an instance, and checks that the proxy stays up: the
# origin secret maps are rendered by after_install.sh's own function with a
# 48-character secret (what the module generates), application_start.sh runs
# for real, and the proxy answers on 443 and on the loopback listener ten
# seconds later. Then the maps change (enforce mode, a new secret, an extra),
# the proxy is recreated, and the same holds. Only the host ports, the TLS
# directory and the app image (a stand-in that answers on 5000) are
# substituted, and validate_service.sh runs for real against the stack in each
# phase (its image prune is shimmed away). nginx.conf alone cannot catch what this does: a map key too
# long for map_hash_bucket_size only fails when the real secret is loaded.
# Skipped without a reachable Docker daemon or the image.
set -eu

TESTS_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly TESTS_DIR
readonly BUNDLE="$TESTS_DIR/../../build/app/bundle"
readonly PORT_TLS="${PROXY_TEST_PORT_TLS:-18443}"
readonly PORT_LOOP="${PROXY_TEST_PORT_LOOP:-18081}"
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

readonly TAG="gramps-stack-test-$$"
# Generated per run: 48 characters is what the module generates, 64 the longest
# it accepts.
random_alnum() {
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$1"
}
SECRET_A="$(random_alnum 48)"
SECRET_B="$(random_alnum 48)"
EXTRA="$(random_alnum 64)"
readonly SECRET_A SECRET_B EXTRA

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gramps-test.XXXXXX")"
cleanup() {
  if [ -f "$WORK/docker-compose.yml" ]; then
    COMPOSE_PROJECT_NAME="$TAG" docker compose --env-file "$WORK/.env" -f "$WORK/docker-compose.yml" down -v >/dev/null 2>&1 || true
  fi
  docker rmi -f "$TAG-app" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

proxy_image() {
  awk '$1 == "proxy:" { in_svc = 1 } in_svc && $1 == "image:" { print $2; exit }' "$BUNDLE/docker-compose.yml"
}

# render MODE SECRET EXTRA: after_install.sh's render_origin_secret, with SSM stubbed.
render() {
  _render_fn="$(awk '/^render_origin_secret\(\) \{/ { p = 1 } p { print } p && /^}/ { exit }' "$BUNDLE/scripts/after_install.sh")"
  sh -c "set -eu
log() { :; }
COMPOSE_DIR='$WORK'
SSM_FRONTEND_CONFIG_PARAM=/gramps-web/prod/frontend-config
ssm_value() { echo '$2'; }
ssm_optional() { case \"\$1\" in */origin-secret-mode) echo '$1' ;; */origin-secret-extra) echo '$3' ;; esac; }
$_render_fn
render_origin_secret"
}

setup() {
  mkdir -p "$WORK/tls" "$WORK/data"
  for _d in db users secret index cache backups tmp; do mkdir -p "$WORK/data/$_d"; done
  openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=origin.example.org -days 1 \
    -keyout "$WORK/tls/privkey.pem" -out "$WORK/tls/fullchain.pem" 2>/dev/null
  cp "$BUNDLE/nginx.conf" "$WORK/nginx.conf"
  python3 - "$BUNDLE/docker-compose.yml" "$WORK" "$PORT_TLS" "$PORT_LOOP" <<'PY'
import sys
src, work, tls, loop = sys.argv[1:]
s = open(src).read()
for old, new in (('"443:443"', f'"{tls}:443"'), ('"127.0.0.1:80:8080"', f'"127.0.0.1:{loop}:8080"'),
                 ("/etc/gramps/tls:/etc/gramps/tls:ro", f"{work}/tls:/etc/gramps/tls:ro")):
    assert old in s, old
    s = s.replace(old, new)
open(work + "/docker-compose.yml", "w").write(s)
PY
  printf 'server {\n    listen 5000;\n    location / { return 200 "ok"; }\n}\n' >"$WORK/app.conf"
  printf 'FROM %s\nCOPY app.conf /etc/nginx/conf.d/default.conf\n' "$IMAGE" >"$WORK/Dockerfile"
  docker build -q -t "$TAG-app" "$WORK" >/dev/null
  printf 'GRAMPS_IMAGE=%s-app\nREGION=us-east-1\nGRAMPS_DATA_ROOT=%s/data\nCELERY_REGION=us-east-1\n' "$TAG" "$WORK" >"$WORK/.env"
  : >"$WORK/app.env"
  : >"$WORK/secrets.env"
  : >"$WORK/config.js"
  printf 'REGION=us-east-1\nCELERY_REGION=us-east-1\nSSM_RUNTIME_PARAM=/p/a\nSSM_FLASK_SECRET_PARAM=/p/b\nSSM_SMTP_PASSWORD_PARAM=/p/c\nSSM_FRONTEND_CONFIG_PARAM=/p/d\nGRAMPS_DATA_ROOT=%s/data\nCOMPOSE_DIR=%s\n' "$WORK" "$WORK" >"$WORK/instance.env"
}

compose() {
  COMPOSE_PROJECT_NAME="$TAG" docker compose --env-file "$WORK/.env" -f "$WORK/docker-compose.yml" "$@"
}

# validate: validate_service.sh, with its URLs and timeout substituted in a copy,
# against the stack.
validate() {
  mkdir -p "$WORK/shim"
  # shellcheck disable=SC2016 # the shim's own variables
  printf '#!/bin/sh\n[ "$1 $2" = "image prune" ] && exit 0\nexec %s "$@"\n' "$(command -v docker)" >"$WORK/shim/docker"
  chmod +x "$WORK/shim/docker"
  _validate_script="$(validate_copy "$BUNDLE/scripts" "$WORK/validate" "http://127.0.0.1:$PORT_LOOP/" "https://127.0.0.1:$PORT_TLS/" 20)"
  _validate_status=0
  PATH="$WORK/shim:$PATH" INSTANCE_ENV="$WORK/instance.env" DEPLOY_LOG="$WORK/deploy.log" COMPOSE_PROJECT_NAME="$TAG" \
    sh "$_validate_script" >"$WORK/validate.log" 2>&1 || _validate_status=$?
  [ "$_validate_status" -eq 0 ] || tail -n 8 "$WORK/validate.log" >&2
  [ "$_validate_status" -eq 0 ] && echo ok || echo failed
}

# status [-H header] URL: the HTTP status, 000 when nothing answers.
status() {
  curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "$@" || true
}

# await_status WANT ARGS...: the status of the request, polled for up to five
# seconds until it is WANT (nginx -s reload returns before the new workers serve).
await_status() {
  _await_status_want="$1"
  shift
  _await_status_i=0
  while [ "$_await_status_i" -lt 10 ]; do
    _await_status_got="$(status "$@")"
    [ "$_await_status_got" != "$_await_status_want" ] || break
    _await_status_i=$((_await_status_i + 1))
    sleep 0.5
  done
  echo "$_await_status_got"
}

# change_proxy_service: edits the compose copy so that `up -d` recreates the proxy.
change_proxy_service() {
  python3 - "$WORK/docker-compose.yml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("\n  proxy:\n", "\n  proxy:\n    labels:\n      probe: recreate\n", 1)
open(p, "w").write(s)
PY
}

# proxy_state: "<status> restarts=<n>" of the proxy container.
proxy_state() {
  docker inspect -f '{{.State.Status}} restarts={{.RestartCount}}' "$(compose ps -q proxy)"
}

# run_start: application_start.sh; prints its exit status on the last line.
run_start() {
  INSTANCE_ENV="$WORK/instance.env" DEPLOY_LOG="$WORK/deploy.log" COMPOSE_PROJECT_NAME="$TAG" \
    sh "$BUNDLE/scripts/application_start.sh" >"$WORK/start.log" 2>&1 && echo 0 || echo 1
}

start_stack() {
  [ "$(run_start)" = 0 ] || {
    echo "FAIL: application_start.sh failed" >&2
    tail -n 20 "$WORK/start.log" >&2
    FAILURES=$((FAILURES + 1))
  }
}

# proxy_id: the proxy container's id.
proxy_id() {
  compose ps -q proxy
}

# stays_up PHASE: ten seconds on, the proxy is running, never restarted.
stays_up() {
  sleep 10
  assert_eq "$1: the proxy is running and has not restarted" "running restarts=0" "$(proxy_state)"
  [ "$(proxy_state)" = "running restarts=0" ] || compose logs --tail 20 proxy >&2
}

main() {
  if ! docker info >/dev/null 2>&1; then
    echo "skip: no Docker daemon"
    return 0
  fi
  IMAGE="$(proxy_image)"
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1 && ! docker pull -q "$IMAGE" >/dev/null 2>&1; then
    echo "skip: cannot pull $IMAGE"
    return 0
  fi
  readonly IMAGE
  setup

  # 1. First start, log mode.
  render log "$SECRET_A" ""
  start_stack
  stays_up "log mode, first start"
  assert_eq "log mode: 443 serves without the header" "200" "$(status "https://127.0.0.1:$PORT_TLS/")"
  assert_eq "log mode: 443 serves with the secret" "200" "$(status -H "X-Origin-Verify: $SECRET_A" "https://127.0.0.1:$PORT_TLS/")"
  assert_eq "log mode: the loopback listener serves" "200" "$(status "http://127.0.0.1:$PORT_LOOP/")"
  assert_eq "log mode: validate_service.sh passes" "ok" "$(validate)"

  # 2. The update path: maps rewritten in place under the running proxy, no
  # recreate, then application_start.sh (nginx -t and reload).
  _main_id="$(proxy_id)"
  render enforce "$SECRET_B" ""
  start_stack
  assert_eq "in-place update: the proxy container is the same" "$_main_id" "$(proxy_id)"
  assert_eq "in-place update: no header is 403" "403" "$(await_status 403 "https://127.0.0.1:$PORT_TLS/")"
  assert_eq "in-place update: the new secret is served" "200" "$(await_status 200 -H "X-Origin-Verify: $SECRET_B" "https://127.0.0.1:$PORT_TLS/")"
  assert_eq "in-place update: the old secret is refused" "403" "$(await_status 403 -H "X-Origin-Verify: $SECRET_A" "https://127.0.0.1:$PORT_TLS/")"
  assert_eq "in-place update: validate_service.sh passes" "ok" "$(validate)"

  # 3. A recreate with changed maps.
  render enforce "$SECRET_B" "$EXTRA,$SECRET_A"
  compose up -d --force-recreate proxy >/dev/null 2>&1
  start_stack
  stays_up "enforce mode, proxy recreated with changed maps"
  assert_eq "enforce: 443 without the header is 403" "403" "$(status "https://127.0.0.1:$PORT_TLS/")"
  assert_eq "enforce: the current secret is served" "200" "$(status -H "X-Origin-Verify: $SECRET_B" "https://127.0.0.1:$PORT_TLS/")"
  assert_eq "enforce: an extra secret is served" "200" "$(status -H "X-Origin-Verify: $EXTRA" "https://127.0.0.1:$PORT_TLS/")"
  assert_eq "enforce: the loopback listener serves without it" "200" "$(status "http://127.0.0.1:$PORT_LOOP/")"
  assert_eq "enforce mode: validate_service.sh passes" "ok" "$(validate)"

  # 4. A map nginx rejects fails the deploy; the running proxy is untouched,
  # even though a changed service makes `up -d` want to recreate it.
  _main_id="$(proxy_id)"
  cp "$WORK/docker-compose.yml" "$WORK/docker-compose.yml.good"
  change_proxy_service
  cp "$WORK/origin-secret.map" "$WORK/origin-secret.map.good"
  printf '"broken" 1\ndefault 0;\n' >"$WORK/origin-secret.map"
  assert_eq "an invalid map fails the deploy" "1" "$(run_start)"
  assert_eq "the pre-flight error is in the deploy output" "yes" "$(grep -q 'emerg' "$WORK/start.log" && echo yes || echo no)"
  assert_eq "an invalid map: the same proxy container" "$_main_id" "$(proxy_id)"
  assert_eq "an invalid map: it still serves the previous secret" "200" "$(status -H "X-Origin-Verify: $SECRET_B" "https://127.0.0.1:$PORT_TLS/")"
  cp "$WORK/origin-secret.map.good" "$WORK/origin-secret.map"

  # 5. The v1.8.0 failure: a nginx.conf without map_hash_bucket_size, with the
  # real 48-character secret, fails the pre-flight, not the running proxy.
  cp "$WORK/nginx.conf" "$WORK/nginx.conf.good"
  grep -v '^map_hash_bucket_size' "$WORK/nginx.conf.good" >"$WORK/nginx.conf"
  assert_eq "a config that cannot hash the secret fails the deploy" "1" "$(run_start)"
  assert_eq "the nginx error names the hash bucket" "yes" "$(grep -q 'map_hash_bucket_size' "$WORK/start.log" && echo yes || echo no)"
  assert_eq "the same proxy container is still running" "$_main_id" "$(proxy_id)"
  assert_eq "and still answers on 443" "200" "$(status -H "X-Origin-Verify: $SECRET_B" "https://127.0.0.1:$PORT_TLS/")"
  cp "$WORK/nginx.conf.good" "$WORK/nginx.conf"
  cp "$WORK/docker-compose.yml.good" "$WORK/docker-compose.yml"
  finish
}

main "$@"
