# Builds the first-party frontend (build/web -- the error pages and the
# status shell) in CodeBuild and publishes straight to
# S3, then invalidates the primary distribution. Manual-trigger only (no
# webhook): these are static pages and rebuilds are intentional. The build logic stays in build/web/; this only
# stands up the project, source auth, and a scoped role so the publish runs
# off a workstation under least privilege.
#
# IAM/env scope tracks which of build/web's pages actually have live
# CloudFront routing: it can write the errors bucket unconditionally, and the
# status bucket when status_bucket_arn is non-null (null when the status
# page is disabled).

data "aws_caller_identity" "current" {}

locals {
  name       = "gramps-web-frontend"
  account_id = data.aws_caller_identity.current.account_id

  # Everything build/web/buildspec.yml's publish step consumes, all sourced
  # from module variables, so the build never needs terraform or the state backend.
  build_env = {
    SITE_TITLE         = var.site_title
    STATUS_PUBLIC_PAGE = tostring(var.status_public_page)
    ERRORS_BUCKET_NAME = var.errors_bucket_name
    # coalesce() rejects "" as a fallback (it counts as absent, same as null),
    # so a plain null check is what turns "disabled" into an empty env var.
    STATUS_BUCKET_NAME = var.status_bucket_name != null ? var.status_bucket_name : ""
    DISTRIBUTION_ID    = var.distribution_id
  }
}

resource "aws_cloudwatch_log_group" "build" {
  name              = "/aws/codebuild/${local.name}"
  retention_in_days = 30

  tags = {
    Name = local.name
  }
}

# CodeBuild S3 cache: holds /root/.npm between builds (see
# build/web/buildspec.yml) so `npm ci` stops re-downloading every tarball on
# every build.
resource "aws_s3_bucket" "cache" {
  bucket = "${local.name}-cache-${local.account_id}"

  tags = {
    Name = "${local.name}-cache"
  }
}

resource "aws_s3_bucket_public_access_block" "cache" {
  bucket                  = aws_s3_bucket.cache.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cache" {
  bucket = aws_s3_bucket.cache.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "cache" {
  bucket = aws_s3_bucket.cache.id

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# TLS-only, matching the estate standard.
data "aws_iam_policy_document" "cache" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.cache.arn, "${aws_s3_bucket.cache.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "cache" {
  bucket = aws_s3_bucket.cache.id
  policy = data.aws_iam_policy_document.cache.json
}

resource "aws_codebuild_project" "web" {
  name         = local.name
  description  = "Builds the first-party frontend (build/web) and publishes it to S3."
  service_role = aws_iam_role.web_build.arn

  # Pulls through the CodeConnections GitHub app the root stack creates and
  # shares with the app and AMI build projects; approve it once (PENDING
  # -> AVAILABLE) before the first build. Swap type/auth here if the repo is
  # not on GitHub.
  source {
    type      = "GITHUB"
    location  = var.repo_url
    buildspec = "build/web/buildspec.yml"

    auth {
      type     = "CODECONNECTIONS"
      resource = var.connection_arn
    }
  }

  source_version = var.source_branch

  # The build publishes to S3 itself; nothing to hand back to CodeBuild.
  artifacts {
    type = "NO_ARTIFACTS"
  }

  cache {
    type     = "S3"
    location = "${aws_s3_bucket.cache.bucket}/cache"
  }

  environment {
    type            = "LINUX_CONTAINER"
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = var.codebuild_image
    privileged_mode = false
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
    Name = local.name
  }
}
