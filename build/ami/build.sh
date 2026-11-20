#!/bin/sh
# Builds the gramps-web-base AMIs (both architectures) with a pinned Packer
# from this directory's gramps-ami.pkr.hcl, then prints the newest AMI per
# architecture as a ready-to-paste ami_ids block. Runs inside the gramps-web-ami
# CodeBuild project (build/ami/buildspec.yml), which then adopts the AMIs
# (scripts/adopt-amis.sh), and from a workstation, which only builds.
#
# Env:
#   REGION              region to build in. CodeBuild injects it; workstation
#                        runs derive it from the module's outputs, using
#                        $GRAMPS_WEB_ROOT like the other scripts.
#   GIT_SHA             commit tagged onto the AMIs. Defaults to
#                        CODEBUILD_RESOLVED_SOURCE_VERSION, then git rev-parse
#                        HEAD.
#   ECR_REPO_URL        registry/repo the grampsweb pull is pinned to.
#   GRAMPS_WEB_VERSION  tag to pull. Both injected by CodeBuild;
#                       empty on a workstation run pulls nothing (pull_images
#                       logs and continues -- see build/ami/install.sh).
#   BUILDER_SSM         "true" connects to the builder over SSM Session
#                       Manager instead of public SSH. CodeBuild injects it;
#                       a workstation run sets it only after the module is
#                       applied (the builder needs its instance profile).
#   BUILDER_SG_ID       security group of the builder, injected with
#                       BUILDER_SSM; empty lets Packer create one.
set -eu

readonly LOG_PREFIX="build-ami"

SCRIPT_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly SCRIPT_DIR
# This component is two levels down; $REPO_ROOT exists only to reach
# scripts/ helpers. The packer files are addressed as $SCRIPT_DIR. Not git rev-parse: the source
# artifact CodeBuild unpacks has no .git.
REPO_ROOT="$(
  unset CDPATH
  cd -- "$SCRIPT_DIR/../.." && pwd
)"
readonly REPO_ROOT
# shellcheck source=../../scripts/keel/common.sh
. "$REPO_ROOT/scripts/keel/common.sh"
# shellcheck source=../../scripts/common.sh
. "$REPO_ROOT/scripts/common.sh"

# Installed when no packer is on PATH (the CodeBuild case). The exact-pinned
# amazon plugin in gramps-ami.pkr.hcl is the other half of the pin; >= 1.14
# is required either way (init pulls official plugins from
# releases.hashicorp.com).
readonly PACKER_VERSION="1.16.2"
readonly PACKER_DIR="/tmp/packer-$PACKER_VERSION"

# The Session Manager plugin Packer shells out to for ssh_interface =
# "session_manager". The checksum is of the pinned release's Ubuntu package,
# computed when the pin was set: AWS publishes none beside it.
readonly SSM_PLUGIN_VERSION="1.2.896.0"
readonly SSM_PLUGIN_SHA256="53f51fcc67314a4bf85888a38a3967cd41f8d0f28a60a9469a63acf935ba713e"
readonly SSM_PLUGIN_DIR="/tmp/session-manager-plugin-$SSM_PLUGIN_VERSION"

install_session_manager_plugin() {
  case "$(uname -sm)" in
  "Linux x86_64") ;;
  *) die "no session-manager-plugin on PATH and auto-install only covers Linux x86_64; install it" ;;
  esac
  log "installing session-manager-plugin $SSM_PLUGIN_VERSION..."
  mkdir -p "$SSM_PLUGIN_DIR"
  (
    cd "$SSM_PLUGIN_DIR"
    curl -fsSLo plugin.deb "https://s3.amazonaws.com/session-manager-downloads/plugin/$SSM_PLUGIN_VERSION/ubuntu_64bit/session-manager-plugin.deb"
    echo "$SSM_PLUGIN_SHA256  plugin.deb" | sha256sum -c -
    dpkg-deb -x plugin.deb root
  )
  PATH="$SSM_PLUGIN_DIR/root/usr/local/sessionmanagerplugin/bin:$PATH"
}

# Pinned download with checksum verification against HashiCorp's published
# SHA256SUMS (fetched alongside: guards a corrupt or truncated download, not
# a compromised origin).
install_packer() {
  case "$(uname -sm)" in
  "Linux x86_64") ;;
  *) die "no packer on PATH and auto-install only covers Linux x86_64; install packer" ;;
  esac
  _install_packer_zip="packer_${PACKER_VERSION}_linux_amd64.zip"
  log "installing packer $PACKER_VERSION..."
  mkdir -p "$PACKER_DIR"
  (
    cd "$PACKER_DIR"
    curl -fsSLO "https://releases.hashicorp.com/packer/$PACKER_VERSION/$_install_packer_zip"
    curl -fsSLO "https://releases.hashicorp.com/packer/$PACKER_VERSION/packer_${PACKER_VERSION}_SHA256SUMS"
    grep " $_install_packer_zip\$" "packer_${PACKER_VERSION}_SHA256SUMS" | sha256sum -c -
    unzip -oq "$_install_packer_zip" packer
  )
  PATH="$PACKER_DIR:$PATH"
}

# The newest gramps-web-base AMI per architecture, printed as the ami_ids block
# the operator can pin.
print_pin_candidates() {
  _print_pin_candidates_block="$(aws ec2 describe-images --region "$REGION" --owners self \
    --filters "Name=tag:Name,Values=gramps-web-base" "Name=state,Values=available" \
    --query 'Images[].{arch:Architecture,id:ImageId,date:CreationDate}' \
    --output json |
    jq -r 'group_by(.arch)[] | max_by(.date) | "  \(.arch) = \"\(.id)\""')"
  log "newest gramps-web-base AMIs. To pin them instead of letting builds advance the launch templates, set ami_ids."
  printf 'ami_ids = {\n%s\n}\n' "$_print_pin_candidates_block" >&2
}

main() {
  require curl unzip sha256sum aws jq
  # The root is consulted only to derive REGION, so only when REGION is absent
  # (the workstation case); CodeBuild always injects it.
  if [ -z "${REGION:-}" ]; then
    select_root "$@"
    init_root
  fi
  readonly REGION
  GIT_SHA="${GIT_SHA:-${CODEBUILD_RESOLVED_SOURCE_VERSION:-}}"
  [ -n "$GIT_SHA" ] || GIT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"
  readonly GIT_SHA
  ECR_REPO_URL="${ECR_REPO_URL:-}"
  readonly ECR_REPO_URL
  GRAMPS_WEB_VERSION="${GRAMPS_WEB_VERSION:-}"
  readonly GRAMPS_WEB_VERSION
  BUILDER_SSM="${BUILDER_SSM:-false}"
  readonly BUILDER_SSM
  BUILDER_SG_ID="${BUILDER_SG_ID:-}"
  readonly BUILDER_SG_ID

  command -v packer >/dev/null 2>&1 || install_packer
  if [ "$BUILDER_SSM" = true ]; then
    command -v session-manager-plugin >/dev/null 2>&1 || install_session_manager_plugin
  fi
  log "using $(packer version | head -n 1) in $REGION (git_sha: ${GIT_SHA:-none}, gramps_web_version: ${GRAMPS_WEB_VERSION:-none})"

  packer init "$SCRIPT_DIR"
  packer validate \
    -var "region=$REGION" -var "git_sha=$GIT_SHA" \
    -var "ecr_repo_url=$ECR_REPO_URL" -var "gramps_web_version=$GRAMPS_WEB_VERSION" \
    -var "ssm_transport=$BUILDER_SSM" -var "builder_security_group_id=$BUILDER_SG_ID" \
    "$SCRIPT_DIR"
  packer build -timestamp-ui \
    -var "region=$REGION" -var "git_sha=$GIT_SHA" \
    -var "ecr_repo_url=$ECR_REPO_URL" -var "gramps_web_version=$GRAMPS_WEB_VERSION" \
    -var "ssm_transport=$BUILDER_SSM" -var "builder_security_group_id=$BUILDER_SG_ID" \
    "$SCRIPT_DIR"

  print_pin_candidates
}

main "$@"
