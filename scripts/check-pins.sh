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
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

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
  local current latest
  current="$(sed -n 's/^readonly PACKER_VERSION="\(.*\)"$/\1/p' "$REPO_ROOT/build/ami/build.sh")"
  latest="$(latest_gh_release hashicorp/packer)"
  report "Packer CLI (build.sh)" "$current" "$latest"
}

check_amazon_plugin() {
  local current latest
  current="$(sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"\(.*\)"$/\1/p' \
    "$REPO_ROOT/build/ami/gramps-ami.pkr.hcl" | head -n 1)"
  latest="$(latest_gh_release hashicorp/packer-plugin-amazon)"
  report "packer-plugin-amazon (gramps-ami.pkr.hcl)" "$current" "$latest"
}

check_terraform() {
  local current latest
  current="$(cat "$REPO_ROOT/.terraform-version")"
  latest="$(latest_gh_release hashicorp/terraform)"
  report "Terraform CLI (.terraform-version)" "$current" "$latest"
}

check_tflint() {
  local current latest
  current="$(sed -n 's/^[[:space:]]*tflint_version:[[:space:]]*v\(.*\)$/\1/p' \
    "$REPO_ROOT/.github/workflows/terraform.yml")"
  latest="$(latest_gh_release terraform-linters/tflint)"
  report "tflint (terraform.yml)" "$current" "$latest"
}

check_tflint_ruleset_aws() {
  local current latest
  current="$(sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"\(.*\)"$/\1/p' \
    "$REPO_ROOT/.tflint.hcl")"
  latest="$(latest_gh_release terraform-linters/tflint-ruleset-aws)"
  report "tflint AWS ruleset (.tflint.hcl)" "$current" "$latest"
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
  local current latest
  current="$(sed -n 's/^          GITLEAKS_VERSION: \(.*\)$/\1/p' "$REPO_ROOT/.github/workflows/ci.yml")"
  latest="$(latest_gh_release gitleaks/gitleaks)"
  report "gitleaks (ci.yml)" "$current" "$latest"
}

# Docker Hub's tag list, newest-first is not guaranteed, so this reads every
# page and takes the highest matching a bare "<major>-alpine" tag. valkey's
# own alpine tags never move backward across a major (they're what "8-alpine"
# vs "9-alpine" distinguishes), so string comparison of the leading digit is
# the whole test.
check_valkey() {
  local current latest page url
  current="$(sed -n 's#.*docker\.io/valkey/valkey:\([0-9]*-alpine\).*#\1#p' \
    "$REPO_ROOT/build/app/bundle/docker-compose.yml" | head -n 1)"
  latest="$current"
  url="https://hub.docker.com/v2/repositories/valkey/valkey/tags?page_size=100"
  while [ -n "$url" ] && [ "$url" != "null" ]; do
    page="$(curl -fsSL "$url")"
    latest="$(printf '%s\n%s' "$latest" "$(echo "$page" | jq -r '.results[].name')" |
      grep -E '^[0-9]+-alpine$' | sort -t- -k1,1n | tail -n1)"
    url="$(echo "$page" | jq -r '.next')"
  done
  if [ "$current" != "$latest" ]; then
    log "valkey (docker-compose.yml): $current -> $latest available -- bump needs an AMI rebuild to keep the pre-pull (build/ami/install.sh)"
    BEHIND=$((BEHIND + 1))
  else
    log "valkey (docker-compose.yml): $current (up to date)"
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
