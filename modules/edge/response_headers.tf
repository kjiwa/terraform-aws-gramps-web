# Security headers on the app, its static assets and the error pages. Not on
# additional_cache_behaviors or the status behaviors: their owners set their
# own. The CSP carries only frame-ancestors, so it cannot break the SPA's
# scripts, styles or map tiles; override = false lets an origin CSP win.
# HSTS omits includeSubdomains and preload: they bind every subdomain of the
# apex, which this module does not own.
resource "aws_cloudfront_response_headers_policy" "security" {
  name    = "gramps-web-security-headers"
  comment = "HSTS, nosniff, referrer policy and frame-ancestors for gramps-web (${var.primary_domain})."

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = false
      preload                    = false
      override                   = true
    }

    content_type_options {
      override = true
    }

    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }

    frame_options {
      frame_option = "SAMEORIGIN"
      override     = false
    }

    content_security_policy {
      content_security_policy = "frame-ancestors 'self'"
      override                = false
    }
  }
}
