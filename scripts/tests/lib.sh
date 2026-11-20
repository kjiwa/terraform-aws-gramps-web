#!/bin/sh
# Assertion helpers for the script tests. Sourced by each test file.
# shellcheck shell=sh

FAILURES=0

assert_eq() {
  if [ "$2" != "$3" ]; then
    echo "FAIL: $1: expected '$2', got '$3'" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

# assert_status NAME EXPECTED COMMAND...
assert_status() {
  _assert_name="$1"
  _assert_want="$2"
  shift 2
  _assert_got=0
  "$@" >/dev/null 2>&1 || _assert_got=$?
  assert_eq "$_assert_name" "$_assert_want" "$_assert_got"
}

# validate_copy SCRIPTS DIR URL TLS_URL TIMEOUT: a copy of SCRIPTS/validate_service.sh in DIR
# (beside its common.sh) with its constants replaced, so the production script
# reads nothing from the environment. Prints the copy's path and fails if a
# constant was not replaced.
validate_copy() {
  _validate_copy_bundle="$1"
  shift
  mkdir -p "$1"
  cp "$_validate_copy_bundle/common.sh" "$1/common.sh"
  sed -e "s|^readonly URL=.*|readonly URL=\"$2\"|" \
    -e "s|^readonly TLS_URL=.*|readonly TLS_URL=\"$3\"|" \
    -e "s|^readonly TIMEOUT=.*|readonly TIMEOUT=$4|" \
    "$_validate_copy_bundle/validate_service.sh" >"$1/validate_service.sh"
  [ "$(grep -c "^readonly URL=\"$2\"\|^readonly TLS_URL=\"$3\"\|^readonly TIMEOUT=$4\$" "$1/validate_service.sh")" -eq 3 ] || return 1
  echo "$1/validate_service.sh"
}

finish() {
  [ "$FAILURES" -eq 0 ] || exit 1
  echo "ok"
}
