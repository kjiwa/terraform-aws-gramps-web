#!/bin/sh
# Tests for build/ami/smoke.sh: it passes on a complete image and names what
# is missing otherwise. systemctl and docker are stubs on PATH; the installed
# files live in a fixture root.
set -eu

TESTS_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly TESTS_DIR
readonly SMOKE="$TESTS_DIR/../../build/ami/smoke.sh"
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gramps-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# STUB_INACTIVE: a unit that is not active; STUB_DISABLED: a unit that is not
# enabled; STUB_MISSING_IMAGE: an image docker does not have.
cat >"$WORK/bin/systemctl" <<'STUB'
#!/bin/sh
[ "$2" = --quiet ] || exit 64
case "$1:$3" in
is-active:"${STUB_INACTIVE:-}" | is-enabled:"${STUB_DISABLED:-}") exit 3 ;;
esac
STUB
cat >"$WORK/bin/docker" <<'STUB'
#!/bin/sh
[ "$3" != "${STUB_MISSING_IMAGE:-}" ] || exit 1
STUB
chmod +x "$WORK/bin/"*
PATH="$WORK/bin:$PATH"

# A complete image: the baked scripts and dnf-automatic configured.
build_root() {
  rm -rf "$WORK/root"
  mkdir -p "$WORK/root/usr/local/bin" "$WORK/root/etc/dnf"
  for _bin in gramps-spot-drain gramps-health-watchdog gramps-rightsize-watchdog keel-rightsize-check; do
    printf '#!/bin/sh\n' >"$WORK/root/usr/local/bin/$_bin"
    chmod +x "$WORK/root/usr/local/bin/$_bin"
  done
  printf '[commands]\nupgrade_type = security\napply_updates = yes\n' >"$WORK/root/etc/dnf/automatic.conf"
}

# run_smoke [VAR=value...] -- IMAGES...: prints the output and the exit status.
run_smoke() {
  _run_env=""
  while [ "$1" != "--" ]; do
    _run_env="$_run_env $1"
    shift
  done
  shift
  # shellcheck disable=SC2086
  env SMOKE_ROOT="$WORK/root" $_run_env sh "$SMOKE" "$@" 2>&1 && echo "status 0" || echo "status $?"
}

main() {
  build_root
  assert_eq "a complete image passes" "1" \
    "$(run_smoke -- valkey:9 nginx:1.30 ecr/gramps:26 | grep -c 'status 0')"

  assert_eq "docker not active fails" "1" \
    "$(run_smoke STUB_INACTIVE=docker -- valkey:9 | grep -c 'docker.service is not active')"
  assert_eq "a missing image is named" "1" \
    "$(run_smoke STUB_MISSING_IMAGE=nginx:1.30 -- valkey:9 nginx:1.30 | grep -c 'image nginx:1.30 is not present')"
  assert_eq "a unit that is not enabled is named" "1" \
    "$(run_smoke STUB_DISABLED=gramps-health-watchdog.timer -- valkey:9 | grep -c 'gramps-health-watchdog.timer is not enabled')"
  assert_eq "dnf-automatic must be set to security updates" "1" \
    "$(sed -i.bak 's/upgrade_type = security/upgrade_type = default/' "$WORK/root/etc/dnf/automatic.conf"; run_smoke -- valkey:9 | grep -c 'dnf-automatic is not set')"
  build_root
  rm "$WORK/root/usr/local/bin/gramps-spot-drain"
  assert_eq "a missing installed script is named" "1" \
    "$(run_smoke -- valkey:9 | grep -c 'gramps-spot-drain is not installed')"
  assert_eq "no images given is a usage error" "1" "$(run_smoke -- | grep -c 'usage')"
  finish
}

main "$@"
