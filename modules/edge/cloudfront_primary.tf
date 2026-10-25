# Static-asset cache policy. The managed CachingOptimized policy (used by
# /_errors/* and the status shell) has min_ttl=1, which
# still honors the origin's own Cache-Control header -- and Gramps Web serves
# its SPA bundle and every other static file (global.css, fonts/*,
# webawesome-styles/*, images/*, manifest.json) with Cache-Control: no-cache,
# so CachingOptimized ends up caching none of it. This policy sets a
# non-zero min_ttl, which wins over an origin no-cache regardless. No
# cookies/headers/query-string in the cache key: none of these paths vary per
# visitor or per query string, and the content-hashed JS bundle self-busts on
# a real change no matter what CloudFront does with it.
resource "aws_cloudfront_cache_policy" "static_assets" {
  name        = "gramps-web-static-assets"
  min_ttl     = 86400
  default_ttl = 86400
  max_ttl     = 31536000

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config {
      cookie_behavior = "none"
    }
    headers_config {
      header_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "none"
    }
  }
}

resource "aws_cloudfront_distribution" "primary" {
  depends_on = [aws_route53_record.origin]

  enabled         = true
  is_ipv6_enabled = true
  http_version    = "http2and3"
  price_class     = "PriceClass_100"
  comment         = "gramps-web primary (${var.primary_domain})"

  # Apex only. www.<primary> is served by aws_cloudfront_distribution.redirect["www"]
  # (301 to apex), not here: Gramps Web keeps auth tokens in localStorage, which is
  # per-origin, so serving the app on both hosts would split a logged-in session.
  aliases = [var.primary_domain]

  origin {
    origin_id   = "ec2-origin"
    domain_name = local.origin_domain

    # Single origin: connect retries only delay the error page (nothing to fail
    # over to). Fail fast so the maintenance page appears in ~2s, not ~30s.
    connection_attempts = 1
    connection_timeout  = 2

    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_protocol_policy   = "http-only"
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_keepalive_timeout = 5
      origin_read_timeout      = 60
    }
  }

  # Independent origin for custom error pages. Must NOT be the EC2 origin: when
  # that origin 5xx's, CloudFront refetches the error page, so it has to come
  # from somewhere that's still up.
  origin {
    origin_id                = "errors-s3"
    domain_name              = aws_s3_bucket.errors.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.errors.id
  }

  # Caller-supplied origins (var.additional_origins), S3 or any other
  # OAC-capable origin, referenced by additional_cache_behaviors.
  dynamic "origin" {
    for_each = var.additional_origins
    content {
      origin_id                = origin.key
      domain_name              = origin.value.domain_name
      origin_access_control_id = origin.value.origin_access_control_id
    }
  }

  # Status page origins (modules/status), reached via OAC like the S3 origins
  # above. Function URLs are HTTPS-only (unlike the EC2 origin's plain-HTTP
  # custom_origin_config), so the Lambda origin needs its own protocol config.
  dynamic "origin" {
    for_each = var.status_origins
    content {
      origin_id                = origin.value.origin_id
      domain_name              = origin.value.domain_name
      origin_access_control_id = origin.value.origin_access_control_id

      dynamic "custom_origin_config" {
        for_each = origin.value.custom_origin ? [1] : []
        content {
          http_port                = 80
          https_port               = 443
          origin_protocol_policy   = "https-only"
          origin_ssl_protocols     = ["TLSv1.2"]
          origin_keepalive_timeout = 5
          origin_read_timeout      = 30
        }
      }
    }
  }

  default_cache_behavior {
    target_origin_id       = "ec2-origin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # Managed policies: CachingDisabled + AllViewer.
    # Gramps Web is dynamic and authed; caching at edge would leak responses across users.
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CachingDisabled
    origin_request_policy_id = "216adef6-5c7f-47e4-b989-5492eafa07d3" # AllViewer
  }

  # Error pages served from S3. No origin request policy: forwarding client
  # headers (Host especially) to an OAC/S3 origin breaks SigV4.
  ordered_cache_behavior {
    path_pattern           = "/_errors/*"
    target_origin_id       = "errors-s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6" # CachingOptimized
  }

  # Caller-supplied behaviors (var.additional_cache_behaviors). Placed before
  # the status behaviors; CloudFront matches in list order, so a caller's
  # pattern must not overlap /_errors/*, /_status*, or the static-asset
  # patterns below.
  dynamic "ordered_cache_behavior" {
    for_each = var.additional_cache_behaviors
    content {
      path_pattern             = ordered_cache_behavior.value.path_pattern
      target_origin_id         = ordered_cache_behavior.value.target_origin_id
      viewer_protocol_policy   = "redirect-to-https"
      allowed_methods          = ordered_cache_behavior.value.allowed_methods
      cached_methods           = ["GET", "HEAD"]
      compress                 = true
      cache_policy_id          = ordered_cache_behavior.value.cache_policy_id
      origin_request_policy_id = ordered_cache_behavior.value.origin_request_policy_id

      dynamic "function_association" {
        for_each = ordered_cache_behavior.value.function_associations
        content {
          event_type   = function_association.value.event_type
          function_arn = function_association.value.function_arn
        }
      }
    }
  }

  # Status page (modules/status): exact path patterns, not a "/_status*"
  # wildcard. ordered_cache_behavior is first-match-wins by list position, and
  # a wildcard would match /_status/public/, which the Lambda's rstrip("/")
  # normalization folds into /_status/public, serving the full public payload
  # from an uncached behavior. Anything else under /_status/ falls through to
  # the app origin without invoking the Lambda.
  dynamic "ordered_cache_behavior" {
    for_each = var.status_behaviors
    content {
      path_pattern             = ordered_cache_behavior.value.path_pattern
      target_origin_id         = ordered_cache_behavior.value.origin_id
      viewer_protocol_policy   = "redirect-to-https"
      allowed_methods          = ["GET", "HEAD", "OPTIONS"]
      cached_methods           = ["GET", "HEAD"]
      compress                 = true
      cache_policy_id          = ordered_cache_behavior.value.cache_policy_id
      origin_request_policy_id = ordered_cache_behavior.value.origin_request_policy_id

      dynamic "function_association" {
        for_each = ordered_cache_behavior.value.rewrite ? [ordered_cache_behavior.value.function_arn] : []
        content {
          event_type   = "viewer-request"
          function_arn = function_association.value
        }
      }
    }
  }

  # Static assets served from the EC2 origin itself (not the S3 origins
  # above): the app ships these with Cache-Control: no-cache and the default
  # behavior is CachingDisabled, so without this every visitor pulls several MB
  # of SPA bundle and CSS/fonts/images through the single-worker origin on every
  # load. These behaviors override that with the non-zero-min_ttl policy
  # above, which a managed policy would not (see its comment).
  #
  # /config.js must be declared FIRST among the behaviors below: it is
  # rendered per-deployment from SSM at instance boot and must stay dynamic,
  # and the *.js pattern that follows would otherwise also match it --
  # CloudFront's ordered_cache_behavior is first-match-wins by list position,
  # same as the status-page comment above. Declared even though it only
  # restates the default behavior's own CachingDisabled semantics, so a later
  # change to the default behavior can't silently start caching it.
  ordered_cache_behavior {
    path_pattern           = "/config.js"
    target_origin_id       = "ec2-origin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    cache_policy_id = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CachingDisabled
  }

  # The rest of the static surface. Mutually exclusive patterns -- no path
  # matches two of these at once -- so unlike /config.js above, their
  # relative order doesn't matter; toset() (as used for the /_status,
  # /_status/ pair above) is fine here too.
  dynamic "ordered_cache_behavior" {
    for_each = toset(["*.js", "*.css", "/fonts/*", "/images/*", "/webawesome-styles/*", "/manifest.json"])
    content {
      path_pattern           = ordered_cache_behavior.value
      target_origin_id       = "ec2-origin"
      viewer_protocol_policy = "redirect-to-https"
      allowed_methods        = ["GET", "HEAD"]
      cached_methods         = ["GET", "HEAD"]
      compress               = true

      cache_policy_id = aws_cloudfront_cache_policy.static_assets.id
    }
  }

  # Map each configured status to its S3 page. response_code preserves the real
  # status (not 200) so monitoring/bots still see the error. Driven by
  # errors.tf's local.error_codes, kept in step with
  # build/web/src/error/pages.ts's ERROR_PAGES keys (see that local's comment).
  dynamic "custom_error_response" {
    for_each = local.error_codes
    content {
      error_code            = tonumber(custom_error_response.key)
      response_code         = tonumber(custom_error_response.key)
      response_page_path    = "/_errors/${custom_error_response.key}.html"
      error_caching_min_ttl = 10
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.this[var.primary_domain].certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = {
    Name = "gramps-web-primary"
  }
}
