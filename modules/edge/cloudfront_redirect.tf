locals {
  # 301 to the primary apex, preserving path and query. Host-independent (only
  # the target apex is interpolated), so one function body covers every
  # redirect distribution below -- the redirect_domains entries and the
  # primary's www.
  redirect_js = <<-EOT
    function handler(event) {
      var req = event.request;
      var qs = Object.keys(req.querystring).map(function (k) {
        var entry = req.querystring[k];
        // multiValue is present when a key repeats (?a=1&a=2); flatten it so
        // the redirect preserves every pair instead of just the first.
        var values = entry.multiValue ? entry.multiValue : [entry];
        return values.map(function (v) { return k + '=' + v.value; }).join('&');
      }).join('&');
      return {
        statusCode: 301,
        statusDescription: 'Moved Permanently',
        headers: {
          location: { value: 'https://${var.primary_domain}' + req.uri + (qs ? '?' + qs : '') }
        }
      };
    }
  EOT

  # One entry per redirect_domains apex (aliases cover both the apex and its
  # www), plus a "www" entry for the primary domain's own www subdomain. All
  # entries 301 to the primary apex via the shared function above.
  redirect_targets = merge(
    { for d in var.redirect_domains : d => {
      aliases     = [d, "www.${d}"]
      cert_domain = d
      }
    },
    {
      "www" = {
        aliases     = ["www.${var.primary_domain}"]
        cert_domain = var.primary_domain
      }
    }
  )
}

resource "aws_cloudfront_function" "redirect_to_primary" {
  name    = "gramps-web-redirect-to-primary"
  runtime = "cloudfront-js-2.0"
  publish = true
  code    = local.redirect_js
}

# Canonical-host redirects: every redirect_domains apex (+ its www) to the
# primary, and the primary's own www to its apex. Gramps Web stores auth
# tokens in localStorage, which is scoped per origin (scheme+host+port), so
# the app must be served on exactly one host -- every other alias
# 301s here instead of serving a session-splitting second origin.
resource "aws_cloudfront_distribution" "redirect" {
  for_each = local.redirect_targets

  # depends_on can't vary per for_each key (Terraform requires a static list,
  # not a computed/conditional expression), so every instance carries the
  # stricter "www" dependency even though only "www" actually needs it: that
  # entry must wait for the www alias to release from the primary
  # distribution (and for that update to reach Deployed) before claiming it
  # here, or the apply races and fails with CNAMEAlreadyExists. Harmless
  # superset for the other entries, whose aliases were never on primary.
  depends_on = [aws_cloudfront_distribution.primary, aws_route53_record.origin]

  enabled         = true
  is_ipv6_enabled = true
  http_version    = "http2and3"
  price_class     = "PriceClass_100"
  comment         = "gramps-web redirect ${each.key == "www" ? "www.${var.primary_domain}" : each.key} -> ${var.primary_domain}"

  aliases = each.value.aliases

  # Origin is never actually reached: the viewer-request function returns 301 before
  # CloudFront contacts the origin. We point at the same EIP as primary so that if the
  # function is ever detached, the failure mode is a clean origin error rather than
  # silently serving the primary site under the wrong hostname.
  origin {
    origin_id   = "ec2-origin"
    domain_name = local.origin_domain

    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_protocol_policy   = "https-only"
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_keepalive_timeout = 5
      origin_read_timeout      = 60
    }
  }

  default_cache_behavior {
    target_origin_id       = "ec2-origin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    cache_policy_id = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CachingDisabled

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.redirect_to_primary.arn
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.this[each.value.cert_domain].certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = {
    Name = each.key == "www" ? "gramps-web-redirect-www" : "gramps-web-redirect-${each.key}"
  }
}
