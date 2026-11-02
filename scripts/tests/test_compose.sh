#!/bin/sh
# Properties of build/app/bundle/docker-compose.yml: the TLS handshake happens
# in the proxy service, never in a gunicorn worker. A worker busy with a slow
# request cannot complete a handshake, and CloudFront gives up after 2 s.
set -eu

TESTS_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly TESTS_DIR
readonly COMPOSE="$TESTS_DIR/../../build/app/bundle/docker-compose.yml"
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

# service_block NAME: the lines of one top-level service.
service_block() {
  awk -v name="$1:" '
    /^services:/ { in_services = 1; next }
    in_services && /^[^ #]/ { in_services = 0 }
    in_services && $0 ~ /^  [a-z_]+:$/ { in_svc = ($1 == name) }
    in_svc { print }
  ' "$COMPOSE"
}

main() {
  _main_published="$(awk '/^ +ports:/ { in_ports = 1; next }
    in_ports && /^ +- / { print $2; next } { in_ports = 0 }' "$COMPOSE" | tr -d '"')"
  assert_eq "only 443:443 is published" "443:443" "$_main_published"

  _main_proxy_ports="$(service_block proxy | grep -c '"443:443"' || true)"
  assert_eq "proxy publishes 443" "1" "$_main_proxy_ports"

  _main_app_ports="$(service_block grampsweb | grep -c 'ports:' || true)"
  assert_eq "grampsweb publishes no ports" "0" "$_main_app_ports"

  _main_certfile="$(grep -c -e '--certfile' "$COMPOSE" || true)"
  assert_eq "no gunicorn TLS arguments" "0" "$_main_certfile"

  finish
}

main "$@"
