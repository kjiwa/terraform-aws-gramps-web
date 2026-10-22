#!/bin/sh
# Properties of the shell sources: nothing reads configuration files or hard-codes
# a config tree, and nothing uses the non-POSIX `local`.
set -eu

TESTS_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly TESTS_DIR
readonly REPO="$TESTS_DIR/../.."
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

# Operator scripts and build scripts; the vendored keel copy and the tests
# themselves are out of scope.
sources() {
  find "$REPO/scripts" "$REPO/build" -name '*.sh' \
    -not -path '*/node_modules/*' -not -path "$REPO/scripts/keel/*" \
    -not -path "$REPO/scripts/tests/*"
}

assert_none() {
  _assert_hits="$(sources | xargs grep -nE -e "$2" || true)"
  [ -z "$_assert_hits" ] || echo "$_assert_hits" >&2
  assert_eq "$1" "" "$_assert_hits"
}

assert_none "no tfvars or config tree" 'terraform/(config|roots)|TFVARS|tfvars|CONFIG_DIR|env_paths|config_paths'
assert_none "no local keyword" '^[[:space:]]*local[[:space:]]'
assert_none "no personal identifiers" 'shivji|kjiwa[^/]|kjiwa$'

assert_eq "no SC3043 exemption" "" "$(grep -n 'SC3043' "$REPO/.shellcheckrc" || true)"

finish
