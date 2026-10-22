#!/bin/sh
# Builds the gramps-web-base AMIs (both architectures) with a pinned Packer
# from this directory's gramps-ami.pkr.hcl, then prints the newest AMI per
# architecture as a ready-to-paste ami_ids block. Runs inside the gramps-web-ami
# CodeBuild project (build/ami/buildspec.yml) and from a workstation. New AMIs
# deploy nothing until pinned in ami_ids (tfvars) and applied.
#
# Env:
#   REGION              region to build in. CodeBuild injects it from
#                        primary_region; workstation runs derive it from the
#                        env's tfvars ($ENV, default prod), like the other
#                        scripts.
#   GIT_SHA             commit tagged onto the AMIs. Defaults to
#                        CODEBUILD_RESOLVED_SOURCE_VERSION, then git rev-parse
#                        HEAD.
#   ECR_REPO_URL        registry/repo the grampsweb pull is pinned to.
#   GRAMPS_WEB_VERSION  tag to pull. Both injected by CodeBuild from tfvars;
#                       empty on a workstation run pulls nothing (pull_images
#                       logs and continues -- see build/ami/install.sh).
set -eu

readonly LOG_PREFIX="build-ami"

SCRIPT_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly SCRIPT_DIR
# This component is two levels down; $REPO_ROOT exists only to reach
# scripts/common.sh and, through env_paths, terraform/config/stack/$ENV. The
# packer files are addressed as $SCRIPT_DIR. Not git rev-parse: the source
# artifact CodeBuild unpacks has no .git.
REPO_ROOT="$(
  unset CDPATH
  cd -- "$SCRIPT_DIR/../.." && pwd
)"
readonly REPO_ROOT
# shellcheck source=../../scripts/common.sh
. "$REPO_ROOT/scripts/common.sh"

# Installed when no packer is on PATH (the CodeBuild case). The exact-pinned
# amazon plugin in gramps-ami.pkr.hcl is the other half of the pin; >= 1.14
# is required either way (init pulls official plugins from
# releases.hashicorp.com).
readonly PACKER_VERSION="1.16.1"
readonly PACKER_DIR="/tmp/packer-$PACKER_VERSION"

# Pinned download with checksum verification against HashiCorp's published
# SHA256SUMS (fetched alongside: guards a corrupt or truncated download, not
# a compromised origin).
install_packer() {
  local zip
  case "$(uname -sm)" in
  "Linux x86_64") ;;
  *) die "no packer on PATH and auto-install only covers Linux x86_64; install packer" ;;
  esac
  zip="packer_${PACKER_VERSION}_linux_amd64.zip"
  log "installing packer $PACKER_VERSION..."
  mkdir -p "$PACKER_DIR"
  (
    cd "$PACKER_DIR"
    curl -fsSLO "https://releases.hashicorp.com/packer/$PACKER_VERSION/$zip"
    curl -fsSLO "https://releases.hashicorp.com/packer/$PACKER_VERSION/packer_${PACKER_VERSION}_SHA256SUMS"
    grep " $zip\$" "packer_${PACKER_VERSION}_SHA256SUMS" | sha256sum -c -
    unzip -oq "$zip" packer
  )
  PATH="$PACKER_DIR:$PATH"
}

# The newest gramps-web-base AMI per architecture, printed as the tfvars block
# the operator pins next.
print_pin_candidates() {
  local block
  block="$(aws ec2 describe-images --region "$REGION" --owners self \
    --filters "Name=tag:Name,Values=gramps-web-base" "Name=state,Values=available" \
    --query 'Images[].{arch:Architecture,id:ImageId,date:CreationDate}' \
    --output json |
    jq -r 'group_by(.arch)[] | max_by(.date) | "  \(.arch) = \"\(.id)\""')"
  log "newest gramps-web-base AMIs. To roll out: pin in terraform/config/stack/<env>/terraform.tfvars, apply."
  printf 'ami_ids = {\n%s\n}\n' "$block" >&2
}

main() {
  require curl unzip sha256sum aws jq
  # The env's tfvars are consulted only to derive REGION, so only look for them
  # when REGION is absent (the workstation case). CodeBuild always injects it,
  # and resolving the env unconditionally would make this project depend on an
  # env directory literally named prod -- breaking a fork whose env is not.
  if [ -z "${REGION:-}" ]; then
    env_paths
    REGION="$(resolve_region "$TFVARS")"
  fi
  readonly REGION
  GIT_SHA="${GIT_SHA:-${CODEBUILD_RESOLVED_SOURCE_VERSION:-}}"
  [ -n "$GIT_SHA" ] || GIT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"
  readonly GIT_SHA
  ECR_REPO_URL="${ECR_REPO_URL:-}"
  readonly ECR_REPO_URL
  GRAMPS_WEB_VERSION="${GRAMPS_WEB_VERSION:-}"
  readonly GRAMPS_WEB_VERSION

  command -v packer >/dev/null 2>&1 || install_packer
  log "using $(packer version | head -n 1) in $REGION (git_sha: ${GIT_SHA:-none}, gramps_web_version: ${GRAMPS_WEB_VERSION:-none})"

  packer init "$SCRIPT_DIR"
  packer validate \
    -var "region=$REGION" -var "git_sha=$GIT_SHA" \
    -var "ecr_repo_url=$ECR_REPO_URL" -var "gramps_web_version=$GRAMPS_WEB_VERSION" \
    "$SCRIPT_DIR"
  packer build -timestamp-ui \
    -var "region=$REGION" -var "git_sha=$GIT_SHA" \
    -var "ecr_repo_url=$ECR_REPO_URL" -var "gramps_web_version=$GRAMPS_WEB_VERSION" \
    "$SCRIPT_DIR"

  print_pin_candidates
}

main "$@"
