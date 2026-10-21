# Static shell for the operational status page (GET /_status, /_status/),
# served from a private S3 bucket via the same OAC pattern as the error pages.
# CloudFront routes /_status and /_status/ to this bucket, while
# /_status/data, /_status/public, and /_status/series route to the status
# Lambda.

resource "aws_s3_bucket" "status_assets" {
  count = var.status_enabled ? 1 : 0

  bucket = "${replace(var.primary_domain, ".", "-")}-status"

  tags = {
    Name = "gramps-web-status-assets"
  }
}

resource "aws_s3_bucket_public_access_block" "status_assets" {
  count  = var.status_enabled ? 1 : 0
  bucket = aws_s3_bucket.status_assets[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "status_assets" {
  count = var.status_enabled ? 1 : 0

  name                              = "gramps-web-status-assets"
  description                       = "OAC for the static status-page shell bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Policy document is shared with the errors bucket -- see
# data.aws_iam_policy_document.cloudfront_read in errors.tf.
resource "aws_s3_bucket_policy" "status_assets" {
  count  = var.status_enabled ? 1 : 0
  bucket = aws_s3_bucket.status_assets[0].id
  policy = data.aws_iam_policy_document.cloudfront_read["status"].json
}

# OAC fronts the S3 REST endpoint, which serves objects literally and does
# not synthesize index.html for a directory-style request.
# Attached to the /_status, /_status/ behaviors in cloudfront_primary.tf.
resource "aws_cloudfront_function" "status_rewrite" {
  count = var.status_enabled ? 1 : 0

  name    = "gramps-web-status-index-rewrite"
  runtime = "cloudfront-js-2.0"
  comment = "Serve status/index.html for /_status and /_status/"
  publish = true
  code    = <<-JS
    function handler(event) {
      var request = event.request;
      var uri = request.uri;
      if (uri === '/_status' || uri === '/_status/') {
        request.uri = '/_status/index.html';
      }
      return request;
    }
  JS
}

# Per-deployment config for the shell, written directly by Terraform --
# main.tsx reads window.gwConfig at module top level before it renders
# anything, so a disabled panel's skeleton is hidden by CSS from first paint
# instead of flashing into view and then vanishing once the real payload
# lands. The explicit cache_control is load-bearing: CachingOptimized's
# 24-hour default_ttl applies only when the origin sends no cache header, and
# Terraform issues no invalidation of its own -- without it, a tfvars toggle
# flip would apply cleanly and stay invisible at the edge for a day.
resource "aws_s3_object" "status_config" {
  count = var.status_enabled ? 1 : 0

  bucket        = aws_s3_bucket.status_assets[0].id
  key           = "_status/config.js"
  content       = "window.gwConfig = ${jsonencode({ disabledPanels = var.status_disabled_panels })};"
  content_type  = "application/javascript"
  cache_control = "public, max-age=60"
}
