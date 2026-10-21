locals {
  # aws_lambda_function_url's function_url output includes the https://
  # scheme and a trailing slash (https://<id>.lambda-url.<region>.on.aws/);
  # CloudFront's origin domain_name wants the bare hostname. Harmless to
  # evaluate when the status feature is off: var.status_function_url is then
  # "", and replace() on "" is still "".
  status_lambda_domain = replace(replace(var.status_function_url, "https://", ""), "/", "")
}

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

  # Status page Lambda Function URL, reached via OAC like the S3 origins
  # above. Function URLs are HTTPS-only (unlike the EC2 origin's plain-HTTP
  # custom_origin_config), so this one needs its own protocol config.
  dynamic "origin" {
    for_each = var.status_enabled ? [1] : []
    content {
      origin_id                = "status-lambda"
      domain_name              = local.status_lambda_domain
      origin_access_control_id = aws_cloudfront_origin_access_control.status[0].id

      custom_origin_config {
        http_port                = 80
        https_port               = 443
        origin_protocol_policy   = "https-only"
        origin_ssl_protocols     = ["TLSv1.2"]
        origin_keepalive_timeout = 5
        origin_read_timeout      = 30
      }
    }
  }

  # Static status-page shell (status_assets.tf), OAC-fronted like errors-s3
  # above.
  dynamic "origin" {
    for_each = var.status_enabled ? [1] : []
    content {
      origin_id                = "status-s3"
      domain_name              = aws_s3_bucket.status_assets[0].bucket_regional_domain_name
      origin_access_control_id = aws_cloudfront_origin_access_control.status_assets[0].id
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

  # Status page: six EXACT path patterns, not the "/_status*" wildcard this
  # replaced. CloudFront's ordered_cache_behavior is first-match-wins by list
  # position, so a wildcard makes correctness depend on where in the list it
  # happens to be declared -- and it swallowed /_status/public/, which
  # lambda/status.py's rstrip("/") normalization folded back into the same
  # path as /_status/public, serving the full public payload off a
  # trailing-slash request from a CachingDisabled behavior on every hit.
  # Exact patterns make precedence irrelevant, and anything else under
  # /_status/ (including that trailing-slash case) falls through to the app
  # origin without ever invoking the Lambda. compress = true on all six --
  # the wildcard behavior it replaced omitted it, so both the ~24 KB shell
  # and the ~19 KB JSON payload shipped uncompressed.

  # Shell: GET /_status and /_status/ both serve the single _status/index.html
  # object build/web/publish.sh publishes (the built pages/status.html shell,
  # see build/web/src/status/) regardless of who's asking, so it is cacheable
  # at the edge -- an exact pattern here can never also match /_status/data
  # or /_status/public, so caching the shell can never accidentally cache a
  # gated response. No origin request policy: forwarding Host to an OAC/S3
  # origin breaks SigV4. The rewrite function maps both patterns to the
  # bucket's index object.
  dynamic "ordered_cache_behavior" {
    for_each = var.status_enabled ? toset(["/_status", "/_status/"]) : toset([])
    content {
      path_pattern           = ordered_cache_behavior.value
      target_origin_id       = "status-s3"
      viewer_protocol_policy = "redirect-to-https"
      allowed_methods        = ["GET", "HEAD", "OPTIONS"]
      cached_methods         = ["GET", "HEAD"]
      compress               = true

      cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6" # CachingOptimized

      function_association {
        event_type   = "viewer-request"
        function_arn = aws_cloudfront_function.status_rewrite[0].arn
      }
    }
  }

  # Per-deployment config for the shell, served straight off the same S3
  # origin as aws_s3_object.status_config (status_assets.tf) writes it to --
  # not the Lambda, since it is plain per-deployment JSON with no per-caller
  # variation. Required, not optional: without this exact pattern,
  # /_status/config.js falls through to the default behavior (ec2-origin),
  # which has no such route and 404s -- the built shell's <script
  # src="/_status/config.js"> would then fail to load on every visit.
  dynamic "ordered_cache_behavior" {
    for_each = var.status_enabled ? [1] : []
    content {
      path_pattern           = "/_status/config.js"
      target_origin_id       = "status-s3"
      viewer_protocol_policy = "redirect-to-https"
      allowed_methods        = ["GET", "HEAD", "OPTIONS"]
      cached_methods         = ["GET", "HEAD"]
      compress               = true

      cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6" # CachingOptimized
    }
  }

  # Gated data route: every response here is per-caller (the X-Gramps-Token
  # bearer's own role and panel data), so it must never be cached -- and it
  # is one of the two behaviors (with /_status/series below) that still
  # need the origin request policy, to carry X-Gramps-Token to the Lambda
  # at all.
  dynamic "ordered_cache_behavior" {
    for_each = var.status_enabled ? [1] : []
    content {
      path_pattern           = "/_status/data"
      target_origin_id       = "status-lambda"
      viewer_protocol_policy = "redirect-to-https"
      allowed_methods        = ["GET", "HEAD", "OPTIONS"]
      cached_methods         = ["GET", "HEAD"]
      compress               = true

      cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CachingDisabled
      origin_request_policy_id = aws_cloudfront_origin_request_policy.status[0].id
    }
  }

  # Gated series route: a panned window is just as caller-specific as
  # /_status/data (the same X-Gramps-Token gate, see lambda/status.py's
  # series_response()), so it gets the identical CachingDisabled +
  # origin-request-policy treatment -- the policy's own query-string
  # whitelist (status.tf) is what actually lets panel/range/end reach the
  # Lambda from here.
  dynamic "ordered_cache_behavior" {
    for_each = var.status_enabled ? [1] : []
    content {
      path_pattern           = "/_status/series"
      target_origin_id       = "status-lambda"
      viewer_protocol_policy = "redirect-to-https"
      allowed_methods        = ["GET", "HEAD", "OPTIONS"]
      cached_methods         = ["GET", "HEAD"]
      compress               = true

      cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CachingDisabled
      origin_request_policy_id = aws_cloudfront_origin_request_policy.status[0].id
    }
  }

  # Public reliability payload: redacted, unauthenticated JSON
  # (lambda/status.py's public_response()). No origin request policy,
  # deliberately -- with no client headers forwarded, X-Gramps-Token can
  # never reach this route, so nothing caller-specific can influence the
  # cache key or leak into the cached response. Gated on both toggles:
  # status_public_reliability without status_enabled is meaningless (there
  # is no Lambda to route to), which the public_reliability validation in
  # variables.tf forbids one layer up.
  dynamic "ordered_cache_behavior" {
    for_each = (var.status_enabled && var.status_public_reliability) ? [1] : []
    content {
      path_pattern           = "/_status/public"
      target_origin_id       = "status-lambda"
      viewer_protocol_policy = "redirect-to-https"
      allowed_methods        = ["GET", "HEAD", "OPTIONS"]
      cached_methods         = ["GET", "HEAD"]
      compress               = true

      cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6" # CachingOptimized
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
