#!/bin/sh
# Static checks on build/ami/gramps-ami.pkr.hcl. Optional argument: the
# template to check.
set -eu

TESTS_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly TESTS_DIR
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

main() {
  _main_template="${1:-$TESTS_DIR/../../build/ami/gramps-ami.pkr.hcl}"

  assert_eq "root volume local is encrypted" 1 \
    "$(grep -c '^ *encrypted *= *true$' "$_main_template")"
  assert_eq "both sources pass the encryption setting" 2 \
    "$(grep -c 'encrypted *= *launch_block_device_mappings.value.encrypted' "$_main_template")"

  if [ "$FAILURES" -gt 0 ]; then
    exit 1
  fi
  echo "ok"
}

main "$@"
