# Static CloudFront custom error pages (502/503/504). Terraform owns the
# bucket, OAC, and read policy below; page content is owned by
# build/web/src/error/ and published directly to this bucket by the
# gramps-web-frontend CodeBuild project (modules/web-build) -- there
# is no aws_s3_object resource here for the pages themselves. This split lets
# deploy.sh web ship error page updates without requiring a Terraform apply.
#
# Consequence: on a fresh stack, /_errors/{502,503,504}.html don't exist
# until the first `deploy.sh web` -- CloudFront serves its own generic error
# in that window. Document it in the deploy sequence rather than working
# around it, since nothing else in this repo self-triggers a build either.

locals {
  # The set of codes CloudFront routes to this bucket (cloudfront_primary.tf's
  # custom_error_response). build/web/src/error/pages.ts's ERROR_PAGES keys
  # are the same three codes, kept as an independent one-line list there --
  # this is infra's "which codes get a route," pages.ts's is copy's "which
  # codes get content," and neither needs the other's shape. Adding a fourth
  # code touches both.
  error_codes = toset(["502", "503", "504"])
}

resource "aws_s3_bucket" "errors" {
  bucket = "${replace(var.primary_domain, ".", "-")}-error-pages"

  tags = {
    Name = "gramps-web-error-pages"
  }
}

resource "aws_s3_bucket_public_access_block" "errors" {
  bucket = aws_s3_bucket.errors.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "errors" {
  name                              = "gramps-web-errors"
  description                       = "OAC for the static error-page bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Scoped to the CloudFront service principal AND this distribution's ARN, so
# block_public_policy accepts the policy.
data "aws_iam_policy_document" "cloudfront_read" {
  statement {
    sid       = "AllowCloudFrontRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.errors.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.primary.arn]
    }
  }

  # TLS-only.
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.errors.arn, "${aws_s3_bucket.errors.arn}/*"]
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

resource "aws_s3_bucket_policy" "errors" {
  bucket = aws_s3_bucket.errors.id
  policy = data.aws_iam_policy_document.cloudfront_read.json
}
