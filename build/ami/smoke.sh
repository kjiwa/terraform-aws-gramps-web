#!/bin/sh
# Smoke check run on the Packer builder after provisioning and before the
# snapshot, so a bad image never becomes an AMI. Fails when any of these is
# missing, naming each:
#   - docker.service is active;
#   - every image given as an argument is in the local image store;
#   - the baked scripts are installed and their units enabled;
#   - dnf-automatic applies security updates.
# It does not boot the finished AMI: cloud-init, user data, the volume attach
# and the app starting are left to the first launch.
#
#   smoke.sh IMAGE...
#
# SMOKE_ROOT prefixes the installed paths (tests).
set -eu

readonly SMOKE_ROOT="${SMOKE_ROOT:-}"
readonly SCRIPTS="gramps-spot-drain gramps-health-watchdog gramps-rightsize-watchdog keel-rightsize-check"
readonly UNITS="gramps-spot-drain.service gramps-health-watchdog.timer gramps-rightsize-watchdog.timer dnf-automatic.timer codedeploy-agent.service amazon-ssm-agent.service"

FAILURES=0

fail() {
  echo "[smoke] FAIL: $*" >&2
  FAILURES=$((FAILURES + 1))
}

check_docker() {
  systemctl is-active --quiet docker || fail "docker.service is not active"
}

check_images() {
  for _check_images_ref in "$@"; do
    docker image inspect "$_check_images_ref" >/dev/null 2>&1 || fail "image $_check_images_ref is not present"
  done
}

check_scripts() {
  for _check_scripts_name in $SCRIPTS; do
    [ -x "$SMOKE_ROOT/usr/local/bin/$_check_scripts_name" ] || fail "$_check_scripts_name is not installed"
  done
}

check_units() {
  for _check_units_name in $UNITS; do
    systemctl is-enabled --quiet "$_check_units_name" || fail "$_check_units_name is not enabled"
  done
}

check_dnf_automatic() {
  _check_dnf_conf="$SMOKE_ROOT/etc/dnf/automatic.conf"
  { grep -q '^upgrade_type = security$' "$_check_dnf_conf" && grep -q '^apply_updates = yes$' "$_check_dnf_conf"; } 2>/dev/null ||
    fail "dnf-automatic is not set to apply security updates"
}

main() {
  if [ "$#" -eq 0 ]; then
    echo "usage: $0 IMAGE..." >&2
    exit 2
  fi
  check_docker
  check_images "$@"
  check_scripts
  check_units
  check_dnf_automatic
  if [ "$FAILURES" -ne 0 ]; then
    echo "[smoke] $FAILURES check(s) failed" >&2
    exit 1
  fi
  echo "[smoke] ok: docker active, $# image(s), $(echo "$SCRIPTS" | wc -w | tr -d ' ') scripts, $(echo "$UNITS" | wc -w | tr -d ' ') units, dnf-automatic"
}

main "$@"
