#!/bin/sh
# Packer provisioner: installs packages, the CodeDeploy agent, the shared
# runtime library the watchdogs source, the Spot interruption drain (script +
# unit, uploaded by the file provisioner), and pre-pulls the valkey and
# grampsweb images.
# Runs as root via: sudo -E sh '{{.Path}}'
# Env vars injected by Packer: REGION, ECR_REPO_URL, GRAMPS_WEB_VERSION
# Files staged under /tmp: everything the file provisioner in
#   gramps-ami.pkr.hcl stages there.
set -eu

log() {
  echo "[packer-install] $*"
}

install_packages() {
  log "Upgrading system packages..."
  dnf upgrade -y

  log "Installing spal-release..."
  dnf install -y spal-release

  # SPAL's docker-compose pairs with SPAL's engine, moby-engine, which declares
  # Conflicts: docker. Never install docker from the core AL2023 repo on these
  # hosts. moby-engine ships dockerd, the docker CLI, and docker.service, so
  # the enable/start below and every `docker` / `docker compose` call works.
  log "Installing moby-engine and docker-compose..."
  dnf install -y moby-engine docker-compose

  systemctl enable docker
  systemctl start docker
  log "Docker: $(docker --version)"
  log "Compose: $(docker compose version)"
}

install_codedeploy_agent() {
  log "Installing CodeDeploy agent..."
  dnf install -y ruby

  _install_codedeploy_agent_tmp_installer="$(mktemp)"
  curl -fsSL -o "$_install_codedeploy_agent_tmp_installer" \
    "https://aws-codedeploy-${REGION}.s3.${REGION}.amazonaws.com/latest/install"
  chmod +x "$_install_codedeploy_agent_tmp_installer"
  "$_install_codedeploy_agent_tmp_installer" auto
  rm -f "$_install_codedeploy_agent_tmp_installer"

  systemctl enable codedeploy-agent
  log "CodeDeploy agent installed."
}

# Ships codedeploy-agent's log, gramps-deploy.log, and cloud-init's two logs
# to CloudWatch (modules/compute/logs.tf's one log group) -- the
# only instance-side visibility into a launch that never reaches app-level
# health checks. Unlike CodeDeploy, the package is in AL2023's own repos, so
# no S3-download dance. fetch-config both converts the JSON to the agent's
# TOML and starts it; stopped again immediately so the build instance's own
# logs don't land in the group, but enabled so a real launch starts it.
install_cloudwatch_agent() {
  log "Installing CloudWatch agent..."
  dnf install -y amazon-cloudwatch-agent

  cat >/tmp/amazon-cloudwatch-agent.json <<'EOF'
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/aws/codedeploy-agent/codedeploy-agent.log",
            "log_group_name": "/gramps-web/instance",
            "log_stream_name": "{instance_id}/codedeploy-agent"
          },
          {
            "file_path": "/var/log/gramps-deploy.log",
            "log_group_name": "/gramps-web/instance",
            "log_stream_name": "{instance_id}/gramps-deploy"
          },
          {
            "file_path": "/var/log/cloud-init.log",
            "log_group_name": "/gramps-web/instance",
            "log_stream_name": "{instance_id}/cloud-init"
          },
          {
            "file_path": "/var/log/cloud-init-output.log",
            "log_group_name": "/gramps-web/instance",
            "log_stream_name": "{instance_id}/cloud-init-output"
          }
        ]
      }
    }
  }
}
EOF

  /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
    -a fetch-config -m ec2 -s -c file:/tmp/amazon-cloudwatch-agent.json
  systemctl stop amazon-cloudwatch-agent
  rm -f /tmp/amazon-cloudwatch-agent.json
  # This run recorded a per-file offset for every collected log; baked into
  # the AMI, it would make every real instance resume from these offsets
  # instead of tailing from the start, skipping early boot entirely.
  rm -rf /opt/aws/amazon-cloudwatch-agent/logs/state
  log "CloudWatch agent configured."
}

# $1 = source basename under /tmp (e.g. "health-watchdog"), $2 = installed
# name under /usr/local/bin and the systemd unit stem (e.g.
# "gramps-health-watchdog"), $3+ = unit suffixes to install ("service",
# "timer"). Enables the last suffix passed, i.e. the timer when there is one.
install_unit() {
  _install_unit_suffix="" _install_unit_last=""
  _install_unit_src="$1"
  _install_unit_name="$2"
  shift 2
  log "Installing $_install_unit_name..."
  install -m 0755 "/tmp/$_install_unit_src.sh" "/usr/local/bin/$_install_unit_name"
  rm -f "/tmp/$_install_unit_src.sh"
  for _install_unit_suffix in "$@"; do
    install -m 0644 "/tmp/$_install_unit_src.$_install_unit_suffix" "/etc/systemd/system/$_install_unit_name.$_install_unit_suffix"
    rm -f "/tmp/$_install_unit_src.$_install_unit_suffix"
    _install_unit_last="$_install_unit_suffix"
  done
  systemctl enable "$_install_unit_name.$_install_unit_last"
}

# Sourced (not executed) by spot-drain.sh, health-watchdog.sh and
# rightsize-watchdog.sh: IMDS/ASG helpers and the runtime SSM parameter poll.
install_runtime_lib() {
  log "Installing gramps-runtime.sh..."
  install -m 0644 /tmp/gramps-runtime.sh /usr/local/lib/gramps-runtime.sh
  rm -f /tmp/gramps-runtime.sh
}

# The valkey pin's single source is the compose file; extract it rather than
# carrying a second copy here (a second copy is exactly what drifts). Fail
# loudly on a miss -- a silent one would quietly put Docker Hub back on the
# boot-critical path.
valkey_image_pin() {
  _valkey_image_pin_image="$(awk '$1 == "valkey:" { in_svc = 1 }
    in_svc && $1 == "image:" { print $2; exit }' /tmp/docker-compose.yml)"
  if [ -z "$_valkey_image_pin_image" ]; then
    log "ERROR: could not extract the valkey image from docker-compose.yml"
    exit 1
  fi
  echo "$_valkey_image_pin_image"
}

# Pre-pulling valkey and grampsweb keeps both off the boot-critical path of a
# replacement: with the tags already local, `compose up` needs no pull at all
# on a same-version launch, which is every launch except a deliberate version
# bump. The grampsweb pull is non-fatal when the tag is absent -- a fresh
# account has an empty ECR repository, and the AMI build must still succeed;
# the deploy pulls it the ordinary way (CodeDeploy's AfterInstall) once the
# app pipeline has actually pushed a version.
pull_images() {
  _pull_images_valkey_image="$(valkey_image_pin)"
  rm -f /tmp/docker-compose.yml
  log "Pulling valkey image: ${_pull_images_valkey_image}..."
  docker pull "$_pull_images_valkey_image"

  if [ -n "${ECR_REPO_URL:-}" ] && [ -n "${GRAMPS_WEB_VERSION:-}" ]; then
    log "Pulling grampsweb image: ${ECR_REPO_URL}:${GRAMPS_WEB_VERSION}..."
    aws ecr get-login-password --region "$REGION" |
      docker login --username AWS --password-stdin "${ECR_REPO_URL%%/*}"
    if ! docker pull "${ECR_REPO_URL}:${GRAMPS_WEB_VERSION}"; then
      log "grampsweb pull failed (tag absent or ECR empty); continuing without it."
    fi
  else
    log "ECR_REPO_URL/GRAMPS_WEB_VERSION not set; skipping the grampsweb pull."
  fi

  log "Disk usage after pull:"
  docker system df
}

cleanup_packages() {
  log "Cleaning the package cache..."
  dnf clean all
  rm -rf /var/cache/dnf
}

# Ensure the SSM agent starts at boot and clear the per-instance state this
# build registered, so instances launched from the AMI register cleanly. The
# installation dir itself is left alone, per AWS guidance.
reset_ssm_agent() {
  log "Resetting SSM agent state..."
  systemctl enable amazon-ssm-agent
  systemctl stop amazon-ssm-agent
  rm -rf /var/lib/amazon/ssm/i-* /var/lib/amazon/ssm/ipc
}

# Packer's build-time SSH key would otherwise land in every instance.
scrub_build_keys() {
  log "Scrubbing the Packer build SSH key..."
  rm -f /root/.ssh/authorized_keys
  rm -f ~ec2-user/.ssh/authorized_keys
}

# cloud-init must run user-data fresh on first instance boot, and the logs
# written during this build would otherwise appear in every instance.
# codedeploy-agent is stopped first (enable, not start, re-launches it on the
# real instance): the installer's "auto" mode leaves it running, and a
# truncate against its open file handle doesn't stick -- it keeps writing at
# its own cursor, including a shutdown-time entry when Packer stops the
# builder, undoing the truncate either way.
reset_cloud_init() {
  log "Resetting cloud-init and truncating build logs..."
  cloud-init clean --logs
  systemctl stop codedeploy-agent
  truncate -s 0 /var/log/messages 2>/dev/null || true
  truncate -s 0 /var/log/secure 2>/dev/null || true
  truncate -s 0 /var/log/aws/codedeploy-agent/codedeploy-agent.log 2>/dev/null || true
  sync
}

cleanup() {
  cleanup_packages
  reset_ssm_agent
  scrub_build_keys
  reset_cloud_init
}

main() {
  log "=== packer-install start ==="
  install_packages
  install_codedeploy_agent
  install_cloudwatch_agent
  install_runtime_lib
  install_unit spot-drain gramps-spot-drain service
  install_unit health-watchdog gramps-health-watchdog service timer
  install_unit rightsize-watchdog gramps-rightsize-watchdog service timer
  install_unit prewarm gramps-prewarm service
  pull_images
  cleanup
  log "=== packer-install complete ==="
}

main "$@"
