#!/bin/sh
# Tests for build/app/bundle/scripts/origin_cert.sh: export, key decryption,
# the serial stamp, and --restart. A stub aws serves a certificate generated
# here with a key encrypted under whatever passphrase the script sent.
set -eu

TESTS_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly TESTS_DIR
readonly SCRIPT="$TESTS_DIR/../../build/app/bundle/scripts/origin_cert.sh"
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gramps-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
ORIGIN_TLS_DIR="$WORK/tls"
ORIGIN_INSTANCE_ENV="$WORK/instance.env"
STUB_SERIAL=01
STUB_LOG="$WORK/calls.log"
export ORIGIN_TLS_DIR ORIGIN_INSTANCE_ENV STUB_SERIAL STUB_LOG WORK

printf 'REGION=us-east-2\nSSM_RUNTIME_PARAM=/gramps-web/prod/gramps-env\nCOMPOSE_DIR=%s\n' "$WORK" >"$ORIGIN_INSTANCE_ENV"
openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=origin.example.org -days 1 \
  -keyout "$WORK/plain.key" -out "$WORK/cert.pem" 2>/dev/null

cat >"$WORK/bin/aws" <<'STUB'
#!/bin/sh
echo "aws $*" >>"$STUB_LOG"
case "$1 $2" in
"ssm get-parameter") echo "arn:aws:acm:us-east-2:111111111111:certificate/abc"; echo "$*" >"$WORK/ssm.args" ;;
"acm describe-certificate") echo "$STUB_SERIAL" ;;
"acm export-certificate")
  _file="${4#file://}"
  _pass="$(sed -n 's/.*"Passphrase":"\([^"]*\)".*/\1/p' "$_file")"
  openssl pkcs8 -topk8 -in "$WORK/plain.key" -passout "pass:$_pass" 2>/dev/null >"$WORK/enc.key"
  { cat "$WORK/cert.pem"; echo; cat "$WORK/cert.pem"; echo; cat "$WORK/enc.key"; } ;;
esac
STUB
cat >"$WORK/bin/docker" <<'STUB'
#!/bin/sh
echo "docker $*" >>"$STUB_LOG"
STUB
chmod +x "$WORK/bin/aws" "$WORK/bin/docker"
PATH="$WORK/bin:$PATH"

run_script() {
  : >"$STUB_LOG"
  sh "$SCRIPT" "$@" >/dev/null
}

count_calls() {
  grep -c "$1" "$STUB_LOG" || true
}

main() {
  run_script
  assert_eq "ssm parameter is a sibling of gramps-env" \
    "ssm get-parameter --name /gramps-web/prod/origin-certificate-arn --query Parameter.Value --output text --region us-east-2" \
    "$(cat "$WORK/ssm.args")"
  assert_eq "private key is decrypted and matches the certificate" \
    "$(openssl pkey -in "$WORK/plain.key" -pubout)" \
    "$(openssl pkey -in "$ORIGIN_TLS_DIR/privkey.pem" -pubout)"
  assert_eq "fullchain holds both certificates" "2" \
    "$(grep -c 'BEGIN CERTIFICATE' "$ORIGIN_TLS_DIR/fullchain.pem")"
  assert_eq "key file is mode 600" "600" "$(stat -c%a "$ORIGIN_TLS_DIR/privkey.pem" 2>/dev/null || stat -f%Lp "$ORIGIN_TLS_DIR/privkey.pem")"
  assert_eq "no work files are left behind" "" "$(find "$ORIGIN_TLS_DIR" -name 'work.*')"
  assert_eq "no restart without --restart" "0" "$(count_calls 'docker')"

  run_script --restart
  assert_eq "unchanged serial does not export" "0" "$(count_calls 'export-certificate')"
  assert_eq "unchanged serial does not restart" "0" "$(count_calls 'docker')"

  STUB_SERIAL=02
  run_script --restart
  assert_eq "new serial exports" "1" "$(count_calls 'export-certificate')"
  assert_eq "new serial restarts grampsweb" "1" "$(count_calls 'docker compose .* restart grampsweb')"
  assert_eq "stamp tracks the serial" "02" "$(cat "$ORIGIN_TLS_DIR/serial")"

  assert_status "unknown flag is refused" 2 sh "$SCRIPT" --bogus
  finish
}

main "$@"
