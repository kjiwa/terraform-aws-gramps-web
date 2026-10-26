#!/bin/sh
# Exports the origin's ACM certificate to disk for gunicorn to serve (mounted
# into grampsweb by docker-compose.yml). Run once by after_install.sh and then
# daily by origin-cert.timer with --restart: ACM renews the certificate in
# place under the same ARN, so a changed serial is the only renewal signal.
# Installed as /usr/local/bin/gramps-origin-cert.
set -eu

readonly INSTANCE_ENV="${ORIGIN_INSTANCE_ENV:-/etc/gramps/instance.env}"
readonly TLS_DIR="${ORIGIN_TLS_DIR:-/etc/gramps/tls}"
readonly STAMP="$TLS_DIR/serial"

log() {
  echo "[origin-cert] $*"
}

load_env() {
  if [ ! -f "$INSTANCE_ENV" ]; then
    log "ERROR: $INSTANCE_ENV not found; instance boot did not complete"
    exit 1
  fi
  # shellcheck disable=SC1090
  . "$INSTANCE_ENV"
  : "${REGION:?REGION missing from $INSTANCE_ENV}"
  : "${SSM_RUNTIME_PARAM:?SSM_RUNTIME_PARAM missing from $INSTANCE_ENV}"
  : "${COMPOSE_DIR:?COMPOSE_DIR missing from $INSTANCE_ENV}"
}

# The certificate ARN parameter is a sibling of the gramps-env parameter
# (modules/compute/ssm.tf), so it needs no instance.env entry of its own.
certificate_arn() {
  aws ssm get-parameter \
    --name "$(dirname -- "$SSM_RUNTIME_PARAM")/origin-certificate-arn" \
    --query 'Parameter.Value' --output text --region "$REGION"
}

certificate_serial() {
  aws acm describe-certificate \
    --certificate-arn "$1" \
    --query 'Certificate.Serial' --output text --region "$REGION"
}

is_current() {
  [ -f "$TLS_DIR/fullchain.pem" ] && [ -f "$TLS_DIR/privkey.pem" ] &&
    [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$1" ]
}

# $1 = certificate ARN, $2 = work dir. Leaves export.pem (certificate, chain
# and the passphrase-encrypted key, newline-joined) and passphrase in $2. The
# passphrase goes to the CLI through a file, not argv, and raw-in-base64-out
# makes the CLI base64-encode it, which the API expects of its blob type.
export_certificate() {
  openssl rand -hex 16 >"$2/passphrase"
  printf '{"CertificateArn":"%s","Passphrase":"%s"}' "$1" "$(cat "$2/passphrase")" >"$2/request.json"
  # The backticks are JMESPath literal syntax, not shell expansion.
  # shellcheck disable=SC2016
  aws acm export-certificate \
    --cli-input-json "file://$2/request.json" \
    --cli-binary-format raw-in-base64-out \
    --query 'join(`"\n"`, [Certificate, CertificateChain, PrivateKey])' \
    --output text --region "$REGION" >"$2/export.pem"
}

# $1 = work dir. Both files land via rename, key first, so a reader never sees
# a half-written file.
install_pem_files() {
  openssl pkey -in "$1/export.pem" -passin "file:$1/passphrase" -out "$1/privkey.pem"
  sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' "$1/export.pem" >"$1/fullchain.pem"
  grep -q 'END CERTIFICATE' "$1/fullchain.pem"
  mv "$1/privkey.pem" "$TLS_DIR/privkey.pem"
  mv "$1/fullchain.pem" "$TLS_DIR/fullchain.pem"
}

restart_app() {
  log "Restarting grampsweb..."
  docker compose \
    --env-file "$COMPOSE_DIR/.env" \
    -f "$COMPOSE_DIR/docker-compose.yml" \
    restart grampsweb
}

main() {
  _main_restart=false
  case "${1:-}" in
  --restart) _main_restart=true ;;
  "") ;;
  *)
    echo "usage: gramps-origin-cert [--restart]" >&2
    exit 2
    ;;
  esac

  load_env
  umask 077
  mkdir -p "$TLS_DIR"
  _main_arn="$(certificate_arn)"
  _main_serial="$(certificate_serial "$_main_arn")"
  if is_current "$_main_serial"; then
    log "Certificate unchanged (serial $_main_serial)."
    return 0
  fi

  log "Exporting certificate (serial $_main_serial)..."
  _main_work="$(mktemp -d "$TLS_DIR/work.XXXXXX")"
  trap 'rm -rf "$_main_work"' EXIT
  export_certificate "$_main_arn" "$_main_work"
  install_pem_files "$_main_work"
  printf '%s\n' "$_main_serial" >"$STAMP"
  log "Certificate installed."

  if [ "$_main_restart" = true ]; then
    restart_app
  fi
}

main "$@"
