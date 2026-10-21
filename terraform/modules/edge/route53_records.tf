resource "aws_route53_record" "origin" {
  zone_id = var.zone_ids[var.primary_domain]
  name    = "origin.${var.primary_domain}"
  type    = "A"
  ttl     = 60
  records = [var.eip_public_ip]
}

locals {
  origin_domain = "origin.${var.primary_domain}"

  alias_records = merge(
    {
      "${var.primary_domain}:apex" = {
        name           = var.primary_domain
        zone_id        = var.zone_ids[var.primary_domain]
        target_domain  = aws_cloudfront_distribution.primary.domain_name
        target_zone_id = aws_cloudfront_distribution.primary.hosted_zone_id
      }
      "${var.primary_domain}:www" = {
        name           = "www.${var.primary_domain}"
        zone_id        = var.zone_ids[var.primary_domain]
        target_domain  = aws_cloudfront_distribution.redirect["www"].domain_name
        target_zone_id = aws_cloudfront_distribution.redirect["www"].hosted_zone_id
      }
    },
    merge([
      for d in var.redirect_domains : {
        "${d}:apex" = {
          name           = d
          zone_id        = var.zone_ids[d]
          target_domain  = aws_cloudfront_distribution.redirect[d].domain_name
          target_zone_id = aws_cloudfront_distribution.redirect[d].hosted_zone_id
        }
        "${d}:www" = {
          name           = "www.${d}"
          zone_id        = var.zone_ids[d]
          target_domain  = aws_cloudfront_distribution.redirect[d].domain_name
          target_zone_id = aws_cloudfront_distribution.redirect[d].hosted_zone_id
        }
      }
    ]...)
  )

  # Flattened for a single alias resource covering both record types: one
  # entry per (alias_records key) x (A, AAAA).
  alias_record_types = merge([
    for key, r in local.alias_records : {
      for t in ["A", "AAAA"] : "${key}:${t}" => merge(r, { record_type = t })
    }
  ]...)
}

resource "aws_route53_record" "alias" {
  for_each = local.alias_record_types

  zone_id = each.value.zone_id
  name    = each.value.name
  type    = each.value.record_type

  alias {
    name                   = each.value.target_domain
    zone_id                = each.value.target_zone_id
    evaluate_target_health = false
  }
}
