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
  # it. git_sha records the commit the build ran from (empty: untracked manual
  # build). source_ami/source_ami_name feed the status page's image panel
  # (modules/status). The {{ }} values are Packer template syntax, resolved by
  # Packer, not Terraform.
  gramps_ami_tags = {
    Name            = "gramps-web-base"
    built_by        = "packer"
    git_sha         = var.git_sha
    source_ami      = "{{ .SourceAMI }}"
    source_ami_name = "{{ .SourceAMIName }}"
  }

  # 24 GiB: a baked instance uses about 9.3 GB (the extracted grampsweb image is
  # 4.2 GB, not its 1.9 GB compressed size) and a version bump pulls a second
  # copy alongside the running one, to about 13.5 GB, leaving headroom for the
  # journal and compose logs.
  gramps_ami_root_volume = {
    device_name           = "/dev/xvda"
    volume_size           = 24
    volume_type           = "gp3"
    delete_on_termination = true
  }

  # Both arches have 2 vCPU and build in about the same time, so the sizes follow
  # what the build needs, not the runtime fleet.
  builder_instance_types = {
    arm64  = "t4g.small"
    x86_64 = "t3.medium"
  }

  # Packer terminates the builder itself via the API once the snapshot is
  # taken; this only fires if that never happens (e.g. the CodeBuild container is
  # killed mid-build, orphaning the instance). Builds take about ten minutes, so 90
  # gives headroom without leaving a dead builder running for long.
  builder_watchdog_user_data = "#!/bin/sh\nshutdown -h +90\n"
}

# Base AMI: OS, Docker, compose, SSM + CodeDeploy agents, the Spot interruption
# drain unit, and valkey and grampsweb both pre-pulled. Baking grampsweb lets
# same-version launches skip the ECR pull; a version bump still pulls the new
# tag via CodeDeploy's AfterInstall. A larger snapshot costs EBS lazy-load
# latency on first read, which gramps-prewarm (prewarm.sh/.service) pays
# concurrently with boot. Rebuild for OS/agent patching or to bake the current
# grampsweb version; a version-only bump does not require it.
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
