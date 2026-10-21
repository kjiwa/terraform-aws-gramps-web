#!/bin/sh
# BeforeInstall: block until instance boot glue is done and Docker is up.
# user-data writes /etc/gramps/instance.env as its LAST step (after the data
# volume is attached/mounted and the EIP associated), so the file's existence
# is the ready signal. It lives in /etc, not /run: it survives reboots, where
# user-data does not re-run but fstab restores the mount, so deploys after an
# in-place reboot still pass. The explicit mountpoint check guards the one
# state the file can't vouch for (a mount that failed to come back), refusing
# to deploy gramps data onto the root volume.
set -eu

SCRIPT_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

# user-data's volume-available wait alone can take up to 600s when the
# previous instance is slow to release the volume; cover that worst case.
readonly INFRA_TIMEOUT=600
readonly DOCKER_TIMEOUT=60

wait_for_infra() {
  local i
  log "Waiting for boot glue ($INSTANCE_ENV)..."
  i=0
  while [ "$i" -lt "$INFRA_TIMEOUT" ]; do
    [ -f "$INSTANCE_ENV" ] && {
      log "Boot glue ready."
      return 0
    }
    i=$((i + 1))
    sleep 1
  done
  log "ERROR: $INSTANCE_ENV not present after ${INFRA_TIMEOUT}s"
  return 1
}

wait_for_docker() {
  local i
  log "Waiting for Docker daemon..."
  i=0
  while [ "$i" -lt "$DOCKER_TIMEOUT" ]; do
    docker info >/dev/null 2>&1 && {
      log "Docker ready."
      return 0
    }
    i=$((i + 1))
    sleep 1
  done
  log "ERROR: Docker not ready after ${DOCKER_TIMEOUT}s"
  return 1
}

# One get-parameters call (plural), so InvalidParameters names every missing
# parameter at once instead of failing on the first ssm_value call in
# after_install.sh with a bare exit 254. --with-decryption also covers KMS
# decrypt on the two SecureStrings, not just parameter existence.
preflight_ssm() {
  local invalid names
  log "Checking SSM parameters..."
  names="$SSM_RUNTIME_PARAM $SSM_FLASK_SECRET_PARAM $SSM_SMTP_PASSWORD_PARAM $SSM_FRONTEND_CONFIG_PARAM"
  # shellcheck disable=SC2086 # word splitting is the interface: --names takes one per word.
  invalid="$(aws ssm get-parameters --with-decryption \
    --names $names \
    --region "$REGION" \
    --query 'InvalidParameters' --output text)"
  if [ -n "$invalid" ] && [ "$invalid" != "None" ]; then
    log "ERROR: SSM parameters missing or undecryptable: $invalid"
    exit 1
  fi
}

main() {
  wait_for_infra
  load_instance_env
  preflight_ssm
  if ! mountpoint -q "$GRAMPS_DATA_ROOT"; then
    log "ERROR: $GRAMPS_DATA_ROOT is not a mountpoint; refusing to deploy onto the root volume"
    exit 1
  fi
  wait_for_docker
}

main "$@"
