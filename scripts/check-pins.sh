#!/bin/sh
# Compares the hand-pinned tool versions no ecosystem bot covers against
# their upstream latest, and prints the ones behind. Dependabot has no
# Packer ecosystem (and neither does Renovate), and nothing reads
# .terraform-version, terraform.yml's setup-tflint version input,
# .tflint.hcl, ci.yml's GITLEAKS_VERSION, or the gramps.version default --
# these pins would otherwise rot silently.
# Read-only: never edits a pin itself, since every one of these has a manual
# consequence (an AMI rebuild, a `tflint --init`, a `tfenv install`) a bot
# can't discharge.
#
#   ./check-pins.sh          human-readable report on stdout
#
# GITHUB_TOKEN, if set, is sent on the GitHub API calls to avoid the
# unauthenticated rate limit (the pins.yml workflow sets it from
# secrets.GITHUB_TOKEN).
set -eu

readonly LOG_PREFIX="pins"

SCRIPT_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly SCRIPT_DIR
REPO_ROOT="$(dirname -- "$SCRIPT_DIR")"
readonly REPO_ROOT
# shellcheck source=keel/common.sh
. "$SCRIPT_DIR/keel/common.sh"

BEHIND=0

gh_auth_header() {
  [ -z "${GITHUB_TOKEN:-}" ] || printf 'Authorization: Bearer %s\n' "$GITHUB_TOKEN"
}

# latest_gh_release OWNER/REPO -> its latest non-prerelease tag, stripped of
# a leading "v" (releases.hashicorp.com and this repo's own pins are both
# unprefixed).
latest_gh_release() {
  curl -fsSL -H "$(gh_auth_header)" \
    "https://api.github.com/repos/$1/releases/latest" |
    jq -r '.tag_name' | sed 's/^v//'
}

# report NAME CURRENT LATEST: prints a line either way, and counts a mismatch.
report() {
  [ -n "$2" ] || die "$1: pin not found"
  if [ "$2" = "$3" ]; then
    log "$1: $2 (up to date)"
  else
    log "$1: $2 -> $3 available"
    BEHIND=$((BEHIND + 1))
  fi
}

check_packer() {
  _check_packer_current="$(sed -n 's/^readonly PACKER_VERSION="\(.*\)"$/\1/p' "$REPO_ROOT/build/ami/build.sh")"
  _check_packer_latest="$(latest_gh_release hashicorp/packer)"
  report "Packer CLI (build.sh)" "$_check_packer_current" "$_check_packer_latest"
}

check_amazon_plugin() {
  _check_amazon_plugin_current="$(sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"\(.*\)"$/\1/p' \
    "$REPO_ROOT/build/ami/gramps-ami.pkr.hcl" | head -n 1)"
  _check_amazon_plugin_latest="$(latest_gh_release hashicorp/packer-plugin-amazon)"
  report "packer-plugin-amazon (gramps-ami.pkr.hcl)" "$_check_amazon_plugin_current" "$_check_amazon_plugin_latest"
}

check_terraform() {
  _check_terraform_current="$(cat "$REPO_ROOT/.terraform-version")"
  _check_terraform_latest="$(latest_gh_release hashicorp/terraform)"
  report "Terraform CLI (.terraform-version)" "$_check_terraform_current" "$_check_terraform_latest"
}

check_tflint() {
  _check_tflint_current="$(sed -n 's/^[[:space:]]*tflint_version:[[:space:]]*v\(.*\)$/\1/p' \
    "$REPO_ROOT/.github/workflows/terraform.yml")"
  _check_tflint_latest="$(latest_gh_release terraform-linters/tflint)"
  report "tflint (terraform.yml)" "$_check_tflint_current" "$_check_tflint_latest"
}

check_tflint_ruleset_aws() {
  _check_tflint_ruleset_aws_current="$(sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"\(.*\)"$/\1/p' \
    "$REPO_ROOT/.tflint.hcl")"
  _check_tflint_ruleset_aws_latest="$(latest_gh_release terraform-linters/tflint-ruleset-aws)"
  report "tflint AWS ruleset (.tflint.hcl)" "$_check_tflint_ruleset_aws_current" "$_check_tflint_ruleset_aws_latest"
}

# The default of the gramps.version variable must track the newest upstream
# grampsweb release, which tags gramps-project/gramps-web (the image tag is the
# same version string).
check_gramps_web() {
  current="$(sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*optional(string, "\([0-9.]*\)")$/\1/p' \
    "$REPO_ROOT/variables.tf" | head -n 1)"
  latest="$(latest_gh_release gramps-project/gramps-web)"
  report "Gramps Web (variables.tf gramps.version)" "$current" "$latest"
}

check_gitleaks() {
  _check_gitleaks_current="$(sed -n 's/^          GITLEAKS_VERSION: \(.*\)$/\1/p' "$REPO_ROOT/.github/workflows/ci.yml")"
  _check_gitleaks_latest="$(latest_gh_release gitleaks/gitleaks)"
  report "gitleaks (ci.yml)" "$_check_gitleaks_current" "$_check_gitleaks_latest"
}

# Docker Hub's tag list, newest-first is not guaranteed, so this reads every
# page and takes the highest matching a bare "<major>-alpine" tag. valkey's
# own alpine tags never move backward across a major (they're what "8-alpine"
# vs "9-alpine" distinguishes), so string comparison of the leading digit is
# the whole test.
check_valkey() {
  _check_valkey_page=""
  _check_valkey_current="$(sed -n 's#.*docker\.io/valkey/valkey:\([0-9]*-alpine\).*#\1#p' \
    "$REPO_ROOT/build/app/bundle/docker-compose.yml" | head -n 1)"
  _check_valkey_latest="$_check_valkey_current"
  _check_valkey_url="https://hub.docker.com/v2/repositories/valkey/valkey/tags?page_size=100"
  while [ -n "$_check_valkey_url" ] && [ "$_check_valkey_url" != "null" ]; do
    _check_valkey_page="$(curl -fsSL "$_check_valkey_url")"
    _check_valkey_latest="$(printf '%s\n%s' "$_check_valkey_latest" "$(echo "$_check_valkey_page" | jq -r '.results[].name')" |
      grep -E '^[0-9]+-alpine$' | sort -t- -k1,1n | tail -n1)"
    _check_valkey_url="$(echo "$_check_valkey_page" | jq -r '.next')"
  done
  if [ "$_check_valkey_current" != "$_check_valkey_latest" ]; then
    log "valkey (docker-compose.yml): $_check_valkey_current -> $_check_valkey_latest available -- bump needs an AMI rebuild to keep the pre-pull (build/ami/install.sh)"
    BEHIND=$((BEHIND + 1))
  else
    log "valkey (docker-compose.yml): $_check_valkey_current (up to date)"
  fi
}

main() {
  require curl jq sed

  check_packer
  check_amazon_plugin
  check_terraform
  check_tflint
  check_tflint_ruleset_aws
  check_gitleaks
  check_gramps_web
  check_valkey

  [ "$BEHIND" -eq 0 ] || die "$BEHIND pin(s) behind upstream"
  log "all pins up to date"
}

main "$@"
