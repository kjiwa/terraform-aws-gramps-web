# Bakes the gramps-web-base AMIs (both architectures) in CodeBuild via
# build/ami/build.sh, so rebuilds run under a scoped role instead of
# workstation admin credentials. Builds start weekly and on a push of the app
# image tag (events.tf), or by hand. After a build passes its smoke check,
# post_build runs scripts/adopt-amis.sh, which repoints the launch templates at
# the new AMIs and starts an instance refresh only when a running AMI is old
# (buildspec.yml).

data "aws_caller_identity" "current" {}

# Packer's builder instance runs in the default VPC (build/ami/gramps-ami.pkr.hcl
# sets no subnet). No ingress: the build reaches it over SSM Session Manager.
data "aws_vpc" "default" {
  default = true
}

resource "aws_security_group" "builder" {
  name        = "gramps-web-ami-builder"
  description = "Packer builder for the gramps-web base AMI: no inbound, the build connects over SSM."
  vpc_id      = data.aws_vpc.default.id

  tags = {
    Name = "gramps-web-ami-builder"
  }
}

resource "aws_vpc_security_group_egress_rule" "builder" {
  security_group_id = aws_security_group.builder.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Package mirrors, ECR, Docker Hub and the SSM endpoints."
}

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
  description  = "Builds the gramps-web-base AMIs (Packer, both architectures) and, unless ami_ids pins them, points the launch templates at them."
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

    environment_variable {
      name  = "BUILDER_SSM"
      value = "true"
    }

    environment_variable {
      name  = "BUILDER_SG_ID"
      value = aws_security_group.builder.id
    }

    environment_variable {
      name  = "ADOPT_AMIS"
      value = tostring(var.adopt_amis)
    }

    environment_variable {
      name  = "ASG_NAME"
      value = var.asg_name
    }

    environment_variable {
      name  = "LAUNCH_TEMPLATE_IDS"
      value = jsonencode(var.launch_template_ids)
    }

    environment_variable {
      name  = "REFRESH_ALARM_NAMES"
      value = jsonencode(var.refresh_alarm_names)
    }

    environment_variable {
      name  = "AMI_MAX_AGE_DAYS"
      value = tostring(var.max_age_days)
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
