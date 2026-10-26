# The CloudFront-to-origin hop is TLS, so the origin host needs a publicly
# trusted certificate. Unlike the viewer certificates in acm.tf this one is
# exportable and lives in the instance's own region (default provider): the
# instance exports it at deploy time (build/app/bundle/scripts/origin_cert.sh)
# and gunicorn serves it directly.
resource "aws_acm_certificate" "origin" {
  domain_name       = local.origin_domain
  validation_method = "DNS"

  options {
    export = "ENABLED"
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "gramps-web-origin-${var.primary_domain}"
  }
}

resource "aws_acm_certificate_validation" "origin" {
  certificate_arn = aws_acm_certificate.origin.arn
  validation_record_fqdns = [
    for k, r in aws_route53_record.cert_validation :
    r.fqdn if local.validation_records[k].domain == local.origin_domain
  ]
}
