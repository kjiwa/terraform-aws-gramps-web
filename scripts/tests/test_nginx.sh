#!/bin/sh
# Runs build/app/bundle/nginx.conf in the pinned nginx image and checks the
# origin secret: the public listener (443) answers 403 without the secret or
# with a wrong one, from any source address, and serves with it; the plain
# listener (8080, published on loopback only) serves without it; the secret is
# not passed to the app. A stand-in app echoes the header it receives. Skipped
# without a reachable Docker daemon or the image.
set -eu

TESTS_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly TESTS_DIR
readonly BUNDLE="$TESTS_DIR/../../build/app/bundle"
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

readonly SECRET="s3cret-value"
readonly TAG="gramps-nginx-test-$$"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gramps-test.XXXXXX")"
cleanup() {
  docker rm -f "$TAG-proxy" "$TAG-app" >/dev/null 2>&1 || true
  docker network rm "$TAG-local" "$TAG-remote" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# The proxy image pin has one source, the compose file.
proxy_image() {
  awk '$1 == "proxy:" { in_svc = 1 } in_svc && $1 == "image:" { print $2; exit }' "$BUNDLE/docker-compose.yml"
}

# probe NETWORK ARGS...: the HTTP status curl gets from a client on NETWORK.
probe() {
  _probe_net="$1"
  shift
  docker run --rm --network "$_probe_net" --entrypoint curl "$IMAGE" -sk -o /dev/null -w '%{http_code}' --max-time 5 "$@" || true
}

# body NETWORK ARGS...: the response body.
body() {
  _body_net="$1"
  shift
  docker run --rm --network "$_body_net" --entrypoint curl "$IMAGE" -sk --max-time 5 "$@" || true
}

start_stack() {
  mkdir -p "$WORK/tls"
  openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=origin.example.org -days 1 \
    -keyout "$WORK/tls/privkey.pem" -out "$WORK/tls/fullchain.pem" 2>/dev/null
  printf '"%s" 1;\ndefault 0;\n' "$SECRET" >"$WORK/origin-secret.map"
  cat >"$WORK/app.conf" <<'CONF'
server {
    listen 5000;
    location / {
        return 200 "app saw secret=[$http_x_origin_verify]";
    }
}
CONF
  # "Remote" callers come from a public-looking subnet, "local" ones from a
  # private bridge: neither may skip the secret on 443.
  docker network create --subnet 198.51.100.0/24 "$TAG-remote" >/dev/null
  docker network create "$TAG-local" >/dev/null
  docker run -d --name "$TAG-app" --network "$TAG-local" --network-alias grampsweb \
    -v "$WORK/app.conf:/etc/nginx/conf.d/default.conf:ro" "$IMAGE" >/dev/null
  docker run -d --name "$TAG-proxy" --network "$TAG-local" \
    -v "$BUNDLE/nginx.conf:/etc/nginx/conf.d/default.conf:ro" \
    -v "$WORK/origin-secret.map:/etc/nginx/origin-secret.map:ro" \
    -v "$WORK/tls:/etc/gramps/tls:ro" "$IMAGE" >/dev/null
  docker network connect "$TAG-remote" "$TAG-proxy"
}

address() {
  docker inspect -f "{{(index .NetworkSettings.Networks \"$TAG-$1\").IPAddress}}" "$TAG-proxy"
}

# Waits for the proxy to answer on the plain listener.
wait_ready() {
  _wait_ready_i=0
  while [ "$_wait_ready_i" -lt 20 ]; do
    [ "$(probe "$TAG-local" "http://$LOCAL_IP:8080/")" = 200 ] && return 0
    _wait_ready_i=$((_wait_ready_i + 1))
    sleep 1
  done
  docker logs "$TAG-proxy" >&2 || true
  return 1
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
  start_stack
  LOCAL_IP="$(address local)"
  REMOTE_IP="$(address remote)"
  wait_ready || {
    echo "FAIL: the proxy did not start" >&2
    FAILURES=$((FAILURES + 1))
    finish
  }

  assert_eq "443, no secret, public-looking source: 403" "403" "$(probe "$TAG-remote" "https://$REMOTE_IP/")"
  assert_eq "443, wrong secret: 403" "403" "$(probe "$TAG-remote" -H 'X-Origin-Verify: nope' "https://$REMOTE_IP/")"
  assert_eq "443, no secret, private source: 403" "403" "$(probe "$TAG-local" "https://$LOCAL_IP/")"
  assert_eq "443, right secret: served" "200" "$(probe "$TAG-remote" -H "X-Origin-Verify: $SECRET" "https://$REMOTE_IP/")"
  assert_eq "the app never receives the secret" "app saw secret=[]" \
    "$(body "$TAG-remote" -H "X-Origin-Verify: $SECRET" "https://$REMOTE_IP/")"
  assert_eq "8080, no secret: served (loopback health listener)" "200" "$(probe "$TAG-local" "http://$LOCAL_IP:8080/")"
  finish
}

main "$@"
