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

cat >"$WORK/bin/curl" <<'STUB'
#!/bin/sh
for _arg in "$@"; do _url="$_arg"; done
echo "curl $_url" >>"$STUB_LOG"
case "$_url" in
https:*) printf '%s' "${STUB_HTTPS:-403}" ;;
*) printf '%s' "${STUB_HTTP:-200}" ;;
esac
STUB
cat >"$WORK/bin/docker" <<'STUB'
#!/bin/sh
echo "docker $*" >>"$STUB_LOG"
STUB
chmod +x "$WORK/bin/"*
PATH="$WORK/bin:$PATH"

# render CODE: runs render_origin_secret with ssm_value defined by CODE.
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

# run_validate [VAR=value...]: runs validate_service.sh against the stubs.
run_validate() {
  : >"$STUB_LOG"
  printf 'REGION=us-east-1\nCELERY_REGION=us-east-1\nSSM_RUNTIME_PARAM=/p/a\nSSM_FLASK_SECRET_PARAM=/p/b\nSSM_SMTP_PASSWORD_PARAM=/p/c\nSSM_FRONTEND_CONFIG_PARAM=/p/d\nGRAMPS_DATA_ROOT=/d\nCOMPOSE_DIR=%s\n' "$WORK/compose" >"$WORK/instance.env"
  env "$@" INSTANCE_ENV="$WORK/instance.env" DEPLOY_LOG="$WORK/deploy.log" VALIDATE_TIMEOUT=1 sh "$BUNDLE/validate_service.sh" >/dev/null 2>&1 && echo "status 0" || echo "status 1"
}

main() {
  # shellcheck disable=SC2016 # the stub body is code for the child shell
  render 'ssm_value() { [ "$1" = /gramps-web/prod/origin-secret ] && echo s3cret; }'
  assert_eq "the map admits the secret and denies the rest" '"s3cret" 1;
default 0;' "$(cat "$WORK/compose/origin-secret.map")"
  assert_eq "the map is private to its owner" "600" "$(stat -c %a "$WORK/compose/origin-secret.map" 2>/dev/null || stat -f %Lp "$WORK/compose/origin-secret.map")"

  rm -f "$WORK/compose/origin-secret.map"
  assert_status "a missing parameter fails the deploy" 1 render 'ssm_value() { return 1; }'
  assert_eq "and leaves no map behind" "no" "$([ -e "$WORK/compose/origin-secret.map" ] && echo yes || echo no)"

  assert_eq "validate: app up on the loopback listener and TLS answering (403 is fine)" "status 0" "$(run_validate STUB_HTTP=200 STUB_HTTPS=403)"
  assert_eq "validate: it reads the app on http://localhost/, not the public listener" "1" \
    "$(grep -c '^curl http://localhost/$' "$STUB_LOG")"
  assert_eq "validate: TLS not answering fails the deploy" "status 1" "$(run_validate STUB_HTTP=200 STUB_HTTPS=000)"
  assert_eq "validate: app down fails the deploy" "status 1" "$(run_validate STUB_HTTP=502 STUB_HTTPS=403)"
  finish
}

main "$@"
