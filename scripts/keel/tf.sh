#!/bin/sh
# Terraform for one root and one config directory. The config directory holds
# terraform.tfvars and backend.hcl and keeps its own .terraform data dir, so
# switching between configs never needs -reconfigure.
#
#   ./tf.sh <root-dir> <config-dir> init                first init
#   ./tf.sh <root-dir> <config-dir> lock                record darwin and linux provider hashes
#   ./tf.sh <root-dir> <config-dir> plan|apply|...      evaluating commands get the tfvars
#   ./tf.sh <root-dir> <config-dir> output|state ...    everything else passes through
set -eu

readonly LOG_PREFIX="tf"

SCRIPT_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly SCRIPT_DIR
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

tf() {
  TF_DATA_DIR="$_main_config_dir/.terraform" terraform -chdir="$_main_root_dir" "$@"
}

main() {
  require terraform
  [ "$#" -ge 3 ] || usage
  _main_root_dir="$1"
  _main_config_dir="$2"
  _main_cmd="$3"
  shift 3
  [ -d "$_main_root_dir" ] || die "no root directory: $_main_root_dir"
  [ -d "$_main_config_dir" ] || die "no config directory: $_main_config_dir"
  _main_config_dir="$(
    unset CDPATH
    cd -- "$_main_config_dir" && pwd
  )"

  case "$_main_cmd" in
  init)
    [ -f "$_main_config_dir/backend.hcl" ] || die "$_main_config_dir/backend.hcl not found"
    tf init -backend-config="$_main_config_dir/backend.hcl" "$@"
    ;;
  lock)
    tf providers lock -platform=darwin_arm64 -platform=darwin_amd64 \
      -platform=linux_amd64 -platform=linux_arm64 "$@"
    ;;
  plan | apply | destroy | refresh | import | console)
    [ -f "$_main_config_dir/terraform.tfvars" ] || die "$_main_config_dir/terraform.tfvars not found"
    tf "$_main_cmd" -var-file="$_main_config_dir/terraform.tfvars" "$@"
    ;;
  *)
    tf "$_main_cmd" "$@"
    ;;
  esac
}

main "$@"
# Vendored from terraform-aws-keel v0.1.0, scripts/tf.sh. Do not edit here: change
# keel and re-vendor. scripts/check-keel-drift.sh fails when this copy differs.
