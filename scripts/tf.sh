#!/bin/sh
# Terraform for one instance of one root. Each root under terraform/roots is
# applied once per instance; this injects that instance's backend config (init)
# or var file (plan/apply/...) and keeps its .terraform data dir separate, so
# switching instances never needs -reconfigure.
#
#   ./tf.sh <instance> init                 first init (or provider bumps)
#   ./tf.sh <instance> lock                 record darwin+linux provider hashes
#   ./tf.sh <instance> plan|apply|destroy   config-evaluating commands (get tfvars)
#   ./tf.sh <instance> output|state ...     everything else passes through
#
# <instance> is a path under terraform/config holding terraform.tfvars and
# backend.hcl: "<root>/<instance>", or a bare "<instance>" meaning
# "stack/<instance>", since the stack is what you work with day to day.
#
#   ./tf.sh prod plan                       the workload env (== stack/prod)
#   ./tf.sh bootstrap/prod apply            that account's state bucket
#   ./tf.sh backup-account/prod-backup plan
#
# The root segment is required for the non-stack roots because it disambiguates:
# a backup account is an instance of both bootstrap and backup-account.
# Credentials (AWS_PROFILE) select the account; each root's account_id
# variable guards against a mismatch.
set -eu

readonly LOG_PREFIX="tf"

SCRIPT_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly SCRIPT_DIR
REPO_ROOT="$(dirname -- "$SCRIPT_DIR")"
readonly REPO_ROOT
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

main() {
  local cmd
  require terraform
  [ "$#" -ge 2 ] ||
    die "usage: $0 [<root>/]<instance> <terraform subcommand> [args...]"
  config_paths "$1"
  shift
  cmd="$1"
  shift

  case "$cmd" in
  init)
    [ -f "$CONFIG_DIR/backend.hcl" ] || die "$CONFIG_DIR/backend.hcl not found"
    tf init -backend-config="$CONFIG_DIR/backend.hcl" "$@"
    ;;
  lock)
    # After a provider bump, init on a Mac records only the darwin h1 hash;
    # CI (linux) then dirties the lock file. Record all three platforms.
    tf providers lock -platform=darwin_arm64 -platform=darwin_amd64 \
      -platform=linux_amd64 "$@"
    ;;
  plan | apply | destroy | refresh | import | console)
    tf "$cmd" -var-file="$TFVARS" "$@"
    ;;
  *)
    tf "$cmd" "$@"
    ;;
  esac
}

main "$@"
