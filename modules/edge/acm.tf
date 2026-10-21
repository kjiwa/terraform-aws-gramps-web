locals {
  all_domains = toset(concat([var.primary_domain], tolist(var.redirect_domains)))

  # Flatten (domain, dvo) pairs so each Route53 validation record gets a stable key.
  validation_records = merge([
    for d in local.all_domains : {
      for dvo in aws_acm_certificate.this[d].domain_validation_options :
      "${d}:${dvo.domain_name}" => {
        domain  = d
        name    = dvo.resource_record_name
        type    = dvo.resource_record_type
        record  = dvo.resource_record_value
        zone_id = var.zone_ids[d]
      }
    }
  ]...)
}

# CloudFront only accepts certificates issued in us-east-1, so these pin to
# the us_east_1 provider alias rather than the default provider's region.
resource "aws_acm_certificate" "this" {
  provider = aws.us_east_1
  for_each = local.all_domains

  domain_name               = each.key
  subject_alternative_names = ["www.${each.key}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "gramps-web-${each.key}"
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = local.validation_records

  zone_id         = each.value.zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  provider = aws.us_east_1
  for_each = local.all_domains

  certificate_arn = aws_acm_certificate.this[each.key].arn
  # Built from the record RESOURCES (not local.validation_records) so the
  # graph orders record creation before this wait.
  validation_record_fqdns = [
    for k, r in aws_route53_record.cert_validation :
    r.fqdn if local.validation_records[k].domain == each.key
  ]
}
