#!/bin/sh
# Properties of the sources: shell reads no tfvars or config tree and uses no
# non-POSIX `local`; no tracked file refers to private tooling or layouts.
# Forbidden words are assembled at run time so this file stays clean.
set -eu

TESTS_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly TESTS_DIR
readonly REPO="$TESTS_DIR/../.."
# shellcheck source=lib.sh
. "$TESTS_DIR/lib.sh"

# Operator scripts, build scripts and the instance user-data template; the
# vendored keel copy and the tests themselves are out of scope.
sources() {
  find "$REPO/scripts" "$REPO/build" "$REPO/modules" \( -name '*.sh' -o -name '*.sh.tftpl' \) \
    -not -path '*/node_modules/*' -not -path "$REPO/scripts/keel/*" \
    -not -path "$REPO/scripts/tests/*"
}

tracked() {
  git -C "$REPO" ls-files -z |
    xargs -0 grep -InE -e "$1" -- 2>/dev/null |
    grep -v '^build/web/package-lock\.json:' || true
}

assert_untracked_words() {
  _assert_words_hits="$(tracked "$2")"
  [ -z "$_assert_words_hits" ] || echo "$_assert_words_hits" >&2
  assert_eq "$1" "" "$_assert_words_hits"
}

assert_none() {
  _assert_hits="$(sources | xargs grep -nE -e "$2" || true)"
  [ -z "$_assert_hits" ] || echo "$_assert_hits" >&2
  assert_eq "$1" "" "$_assert_hits"
}

main() {
  assert_none "no tfvars or config tree" 'TFVARS|tfvars|CONFIG_DIR|env_paths|config_paths'
  assert_none "no local keyword" '^[[:space:]]*local[[:space:]]'
  assert_none "no personal identifiers" 'kjiwa[^/]|kjiwa$'

  _main_words="$(printf '%s|' "data""viz" "(^|[^a-z])est""ate" "bootstrap""/" "modules/audit""/monitor" "palette""\\.md" "shiv""ji" "ro""ots/")"
  assert_untracked_words "no private tooling or layout references" "${_main_words%|}"

  assert_eq "no SC3043 exemption" "" "$(grep -n 'SC3043' "$REPO/.shellcheckrc" || true)"
  finish
}

main "$@"
