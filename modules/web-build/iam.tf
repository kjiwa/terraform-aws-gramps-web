data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "web_build" {
  name               = "${local.name}-build"
  assume_role_policy = data.aws_iam_policy_document.assume.json

  tags = {
    Name = "${local.name}-build"
  }
}

# Least privilege: write only the buckets this build project actually
# publishes to today (see main.tf's header comment on why that's narrower
# than the full set of pages build/web builds), invalidate only the primary
# distribution, use only this one connection. No terraform/state access --
# every destination arrives as a plaintext env var on the project.
data "aws_iam_policy_document" "web_build" {
  statement {
    sid     = "Logs"
    effect  = "Allow"
    actions = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [
      aws_cloudwatch_log_group.build.arn,
      "${aws_cloudwatch_log_group.build.arn}:*",
    ]
  }

  # Pull source through the CodeConnections GitHub app. If IAM rejects the
  # codeconnections: prefix in your partition, swap to codestar-connections:.
  statement {
    sid       = "UseConnection"
    effect    = "Allow"
    actions   = ["codeconnections:GetConnectionToken", "codeconnections:GetConnection", "codeconnections:UseConnection"]
    resources = [var.connection_arn]
  }

  # Publish: sync --delete needs list + put + delete. No GetObject (sync
  # compares by listing, not by reading object bodies).
  statement {
    sid       = "ErrorsBucketWrite"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:PutObject", "s3:DeleteObject"]
    resources = [var.errors_bucket_arn, "${var.errors_bucket_arn}/*"]
  }

  # publish_status uses `cp`, not `sync`: no ListBucket, and the grant names
  # _status/index.html exactly.
  dynamic "statement" {
    for_each = var.status_bucket_arn != null ? [var.status_bucket_arn] : []
    content {
      sid       = "StatusIndexWrite"
      effect    = "Allow"
      actions   = ["s3:PutObject"]
      resources = ["${statement.value}/_status/index.html"]
    }
  }

  statement {
    sid       = "Invalidate"
    effect    = "Allow"
    actions   = ["cloudfront:CreateInvalidation"]
    resources = ["arn:aws:cloudfront::${local.account_id}:distribution/${var.distribution_id}"]
  }

  # CodeBuild S3 cache. Grants ListBucket because the CodeBuild agent issues a
  # bucket-level ListBucket before GetObject on cache lookup.
  statement {
    sid       = "Cache"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.cache.arn]
  }

  statement {
    sid       = "CacheObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${aws_s3_bucket.cache.arn}/*"]
  }
}

resource "aws_iam_role_policy" "web_build" {
  name   = "${local.name}-build"
  role   = aws_iam_role.web_build.id
  policy = data.aws_iam_policy_document.web_build.json
}
