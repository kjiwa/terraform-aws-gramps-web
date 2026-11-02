#!/bin/sh
# azmove.sh adopts the data volume by the tail of its state address. That tail
# must be where modules/storage actually keeps the volume, so a module that
# relocates the volume breaks this test rather than the first AZ move.
set -eu

TESTS_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly TESTS_DIR
readonly ROOT="$TESTS_DIR/../.."
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

main() {
  _main_target="$(sed -n 's/^ *to *= *\(module\.[a-z_]*\.aws_ebs_volume\.this\) *$/\1/p' "$ROOT/modules/storage/moved.tf")"
  _main_suffix="$(sed -n 's/^readonly VOL_RESOURCE_SUFFIX="\(.*\)"$/\1/p' "$ROOT/scripts/azmove.sh")"
  assert_eq "azmove adopts the volume where modules/storage keeps it" \
    "module.storage.$_main_target" "$_main_suffix"
  finish
}

main "$@"
