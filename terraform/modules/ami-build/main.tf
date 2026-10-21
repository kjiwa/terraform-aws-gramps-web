# Bakes the gramps-web-base AMIs (both architectures) in CodeBuild via
# build/ami/build.sh, so patch rebuilds run under a scoped role instead of
# workstation admin credentials. Manual-trigger only (no webhook): the base
# AMI is rebuilt for OS/agent patching on its own cadence, not per commit.
# The resulting AMIs deploy nothing until pinned in ami_ids (tfvars) and
# applied -- the build produces artifacts, terraform owns rollout.

data "aws_caller_identity" "current" {}

locals {
  name       = "gramps-web-ami"
  account_id = data.aws_caller_identity.current.account_id
}

resource "aws_cloudwatch_log_group" "build" {
  name              = "/aws/codebuild/${local.name}"
  retention_in_days = 30

  tags = {
    Name = local.name
  }
}

resource "aws_codebuild_project" "ami" {
  name         = local.name
  description  = "Builds the gramps-web-base AMIs (Packer, both architectures). Roll out by pinning ami_ids in tfvars and applying."
  service_role = aws_iam_role.ami_build.arn

  source {
    type      = "GITHUB"
    location  = var.repo_url
    buildspec = "build/ami/buildspec.yml"

    auth {
      type     = "CODECONNECTIONS"
      resource = var.connection_arn
    }
  }

  source_version = var.source_branch

  # Packer registers the AMIs itself; nothing to hand back to CodeBuild.
  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    type            = "LINUX_CONTAINER"
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = var.codebuild_image
    privileged_mode = false
    host_kernel     = "LINUX_KERNEL_6" # AL2023 host; AL2 is deprecated

    environment_variable {
      name  = "REGION"
      value = var.region
    }

    environment_variable {
      name  = "ECR_REPO_URL"
      value = var.ecr_repository_url
    }

    environment_variable {
      name  = "GRAMPS_WEB_VERSION"
      value = var.gramps_web_version
    }
  }

  logs_config {
    cloudwatch_logs {
      status     = "ENABLED"
      group_name = aws_cloudwatch_log_group.build.name
    }
  }

  tags = {
    Name = local.name
  }
}
