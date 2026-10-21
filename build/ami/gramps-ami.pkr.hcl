packer {
  required_plugins {
    amazon = {
      # Exact pin: Packer has no lock file, so this constraint IS the
      # reproducibility pin (paired with the Packer version pinned in
      # build/ami/build.sh). Requires Packer >= 1.14, whose init pulls
      # official plugins from releases.hashicorp.com.
      version = "1.8.2"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

# Commit the AMI was built from, tagged onto both images for provenance.
# build/ami/build.sh passes it (CODEBUILD_RESOLVED_SOURCE_VERSION in CI,
# git rev-parse on a workstation); empty means an untracked manual build.
variable "git_sha" {
  type    = string
  default = ""
}

# Registry and tag for the grampsweb image install.sh bakes into the AMI.
# Empty is a valid build (a fresh account with no image pushed yet, or a
# workstation build with nothing set) -- pull_images logs and continues.
variable "ecr_repo_url" {
  type    = string
  default = ""
}

variable "gramps_web_version" {
  type    = string
  default = ""
}

locals {
  # Name is the stable tag every base AMI carries; both arches share it (the
  # architecture attribute disambiguates) and scripts/clean-amis.sh selects on
  # it. The deployed AMI is pinned per arch in tfvars (ami_ids), not
  # discovered. git_sha records the commit the build ran from (empty:
  # untracked manual build). source_ami/source_ami_name are provenance for the
  # status page's image panel (modules/status): which upstream
  # AL2023 AMI this build started from. Packer template engine syntax
  # (resolved by Packer itself, not Terraform), left literal.
  gramps_ami_tags = {
    Name            = "gramps-web-base"
    built_by        = "packer"
    git_sha         = var.git_sha
    source_ami      = "{{ .SourceAMI }}"
    source_ami_name = "{{ .SourceAMIName }}"
  }

  # 24 GiB: measured on a live instance from GrampsWeb/DiskUsedBytes -- 5.05 GB
  # before the pull, 9.26 GB after (the extracted grampsweb image is 4.21 GB, not
  # the 1.87 GB compressed ECR size). A fresh baked instance starts at 9.26 GB,
  # and a version bump pulls a second copy alongside the running one to 13.47 GB;
  # 24 GiB puts that at 52% of usable, leaving headroom for the journal and
  # compose logs on the same filesystem. Shared by both arches.
  gramps_ami_root_volume = {
    device_name           = "/dev/xvda"
    volume_size           = 24
    volume_type           = "gp3"
    delete_on_termination = true
  }

  # Both arches sit at 2 vCPU, and the 2 GiB arm64 box builds no slower than the
  # 4 GiB x86 one (3m27s vs 3m42s in install.sh), so the sizes are set by what the
  # build needs, not by matching the runtime fleet.
  builder_instance_types = {
    arm64  = "t4g.small"
    x86_64 = "t3.medium"
  }

  # Packer terminates the builder itself via the API once the snapshot is
  # taken; this only fires if that never happens (e.g. the CodeBuild container is
  # killed mid-build, orphaning the instance). Builds run ~20min measured, so 90
  # gives headroom without leaving a dead builder running for long.
  builder_watchdog_user_data = "#!/bin/sh\nshutdown -h +90\n"
}

# Base AMI: OS, Docker, compose, SSM + CodeDeploy agents, the Spot interruption
# drain unit, and valkey and grampsweb both pre-pulled. Baking grampsweb makes
# same-version launches (every replacement except a deliberate version bump)
# skip the ~99s ECR pull entirely; a version bump still pulls the new tag via
# CodeDeploy's AfterInstall. Baking the image nearly quadrupled this snapshot's
# hydrate-on-first-touch size (2.4GB -> 8.4GB measured), which cost more in EBS
# lazy-load latency than the pull it removed -- gramps-prewarm
# (prewarm.sh/.service) exists to pay that cost concurrently with boot instead
# of serially against the app's own cold-import reads. Rebuild this AMI for
# OS/agent patching or to bake the current grampsweb version; a version-only
# bump doesn't require it (the deploy pulls, just slower until the next
# base-AMI rebuild).
source "amazon-ebs" "gramps" {
  region = var.region

  source_ami_filter {
    filters = {
      name                = "al2023-ami-2023.*-kernel-*-arm64"
      virtualization-type = "hvm"
      root-device-type    = "ebs"
      architecture        = "arm64"
    }
    owners      = ["amazon"]
    most_recent = true
  }

  instance_type = local.builder_instance_types.arm64

  # ECR read for the grampsweb pull below; scoped to the gramps-web repo, see
  # modules/ami-build/iam.tf. Only present once module.ami_build has
  # applied, so a workstation build with no ECR repo yet (install.sh's pull is
  # already conditional for this) omits the profile instead of failing to find it.
  iam_instance_profile = var.ecr_repo_url != "" ? "gramps-web-ami-builder" : null

  ssh_username = "ec2-user"

  # See builder_watchdog_user_data above for why this pair exists.
  shutdown_behavior = "terminate"
  user_data         = local.builder_watchdog_user_data

  ami_name        = "gramps-web-base-arm64-{{timestamp}}"
  ami_description = "Gramps Web base. docker + compose + ssm/codedeploy agents, valkey and grampsweb pre-pulled (pins: build/app/bundle/docker-compose.yml, gramps_web_version)."

  dynamic "launch_block_device_mappings" {
    for_each = [local.gramps_ami_root_volume]
    content {
      device_name           = launch_block_device_mappings.value.device_name
      volume_size           = launch_block_device_mappings.value.volume_size
      volume_type           = launch_block_device_mappings.value.volume_type
      delete_on_termination = launch_block_device_mappings.value.delete_on_termination
    }
  }

  # The builder instance's tag: the gramps-web-ami CodeBuild role scopes its
  # Stop/TerminateInstances grant to it, so the build can only kill its own
  # instances.
  run_tags = {
    Name = "packer-builder-gramps-web"
  }

  tags = local.gramps_ami_tags
}

# x86_64 sibling of the arm64 source above. Identical OS image lineage and
# provisioner; differs only in the builder architecture and the spot pools used
# to build it. install.sh is arch-agnostic (dnf, the CodeDeploy region install
# script, and the valkey pull all resolve per-arch).
source "amazon-ebs" "gramps_x86" {
  region = var.region

  source_ami_filter {
    filters = {
      name                = "al2023-ami-2023.*-kernel-*-x86_64"
      virtualization-type = "hvm"
      root-device-type    = "ebs"
      architecture        = "x86_64"
    }
    owners      = ["amazon"]
    most_recent = true
  }

  instance_type = local.builder_instance_types.x86_64

  # See the arm64 source for the ECR read grant this needs and why it's conditional.
  iam_instance_profile = var.ecr_repo_url != "" ? "gramps-web-ami-builder" : null

  ssh_username = "ec2-user"

  # See the arm64 source for why this pair exists.
  shutdown_behavior = "terminate"
  user_data         = local.builder_watchdog_user_data

  ami_name        = "gramps-web-base-x86-{{timestamp}}"
  ami_description = "Gramps Web base (x86_64). docker + compose + ssm/codedeploy agents, valkey and grampsweb pre-pulled (pins: build/app/bundle/docker-compose.yml, gramps_web_version)."

  dynamic "launch_block_device_mappings" {
    for_each = [local.gramps_ami_root_volume]
    content {
      device_name           = launch_block_device_mappings.value.device_name
      volume_size           = launch_block_device_mappings.value.volume_size
      volume_type           = launch_block_device_mappings.value.volume_type
      delete_on_termination = launch_block_device_mappings.value.delete_on_termination
    }
  }

  # See the arm64 source for the tag semantics.
  run_tags = {
    Name = "packer-builder-gramps-web"
  }

  tags = local.gramps_ami_tags
}

build {
  sources = ["source.amazon-ebs.gramps", "source.amazon-ebs.gramps_x86"]

  # The shared runtime library, the Spot interruption drain, app health
  # watchdog, rightsize watchdog, and pre-warm sweep (scripts + systemd
  # units); install.sh moves these into place and enables the units. Staged
  # in /tmp because the file provisioner runs as the unprivileged SSH user.
  provisioner "file" {
    sources = [
      "${path.root}/gramps-runtime.sh",
      "${path.root}/spot-drain.sh",
      "${path.root}/spot-drain.service",
      "${path.root}/health-watchdog.sh",
      "${path.root}/health-watchdog.service",
      "${path.root}/health-watchdog.timer",
      "${path.root}/rightsize-watchdog.sh",
      "${path.root}/rightsize-watchdog.service",
      "${path.root}/rightsize-watchdog.timer",
      "${path.root}/prewarm.sh",
      "${path.root}/prewarm.service",
      "${path.root}/../app/bundle/docker-compose.yml",
    ]
    destination = "/tmp/"
  }

  provisioner "shell" {
    script          = "${path.root}/install.sh"
    execute_command = "{{ .Vars }} sudo -E sh '{{ .Path }}'"
    environment_vars = [
      "REGION=${var.region}",
      "ECR_REPO_URL=${var.ecr_repo_url}",
      "GRAMPS_WEB_VERSION=${var.gramps_web_version}",
    ]
  }
}
