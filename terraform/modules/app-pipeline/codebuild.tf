resource "aws_cloudwatch_log_group" "build" {
  name              = "/aws/codebuild/${local.name}-build"
  retention_in_days = 30

  tags = {
    Name = "${local.name}-build"
  }
}

resource "aws_codebuild_project" "build" {
  name         = "${local.name}-build"
  description  = "Builds the Gramps Web image (upstream release + addons) and pushes a multi-arch index to ECR."
  service_role = aws_iam_role.build.arn

  source {
    type      = "CODEPIPELINE"
    buildspec = "build/app/buildspec.yml"
  }

  artifacts {
    type = "CODEPIPELINE"
  }

  # Best-effort host-local docker layer cache. The dominant repeated cost is
  # pulling the multi-GB grampsweb base (detect_series does a full `docker run`
  # pull from GHCR every build); on a warm host that pull is a no-op. S3 cache
  # is not an alternative here: it cannot hold docker layers, and the only npm
  # work (frontend override) is off in the normal case.
  cache {
    type  = "LOCAL"
    modes = ["LOCAL_DOCKER_LAYER_CACHE"]
  }

  environment {
    type            = "LINUX_CONTAINER"
    compute_type    = "BUILD_GENERAL1_MEDIUM"
    image           = var.codebuild_image
    privileged_mode = true             # docker buildx
    host_kernel     = "LINUX_KERNEL_6" # AL2023 host; AL2 is deprecated

    # local.build_env, minus empty values: CodeBuild rejects empty env var
    # values, and the script treats absent and empty identically.
    dynamic "environment_variable" {
      for_each = { for k, v in local.build_env : k => v if v != "" }
      content {
        name  = environment_variable.key
        value = environment_variable.value
      }
    }
  }

  logs_config {
    cloudwatch_logs {
      status     = "ENABLED"
      group_name = aws_cloudwatch_log_group.build.name
    }
  }

  tags = {
    Name = "${local.name}-build"
  }
}
