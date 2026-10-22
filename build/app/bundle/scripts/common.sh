#!/bin/sh
# Sourced by the CodeDeploy lifecycle hooks. Defines logging and loads the
# per-instance wiring that Terraform drops at /etc/gramps/instance.env
# (REGION, SSM parameter names, data/compose paths). Keeping these here means
# the revision bundle stays environment-agnostic. No `set -eu` here: every
# hook sets it before sourcing.
# shellcheck shell=sh

readonly INSTANCE_ENV="/etc/gramps/instance.env"

log() {
  echo "[codedeploy] $*" | tee -a /var/log/gramps-deploy.log >&2
}

load_instance_env() {
  if [ ! -f "$INSTANCE_ENV" ]; then
    log "ERROR: $INSTANCE_ENV not found; instance boot did not complete"
    exit 1
  fi
  # shellcheck disable=SC1090
  . "$INSTANCE_ENV"

  : "${REGION:?REGION missing from $INSTANCE_ENV}"
  : "${CELERY_REGION:?CELERY_REGION missing from $INSTANCE_ENV}"
  : "${SSM_RUNTIME_PARAM:?SSM_RUNTIME_PARAM missing from $INSTANCE_ENV}"
  : "${SSM_FLASK_SECRET_PARAM:?SSM_FLASK_SECRET_PARAM missing from $INSTANCE_ENV}"
  : "${SSM_SMTP_PASSWORD_PARAM:?SSM_SMTP_PASSWORD_PARAM missing from $INSTANCE_ENV}"
  : "${SSM_FRONTEND_CONFIG_PARAM:?SSM_FRONTEND_CONFIG_PARAM missing from $INSTANCE_ENV}"
  : "${GRAMPS_DATA_ROOT:?GRAMPS_DATA_ROOT missing from $INSTANCE_ENV}"
  : "${COMPOSE_DIR:?COMPOSE_DIR missing from $INSTANCE_ENV}"
}
