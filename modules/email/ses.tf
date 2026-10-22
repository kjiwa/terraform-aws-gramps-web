data "aws_region" "current" {}

locals {
  region           = data.aws_region.current.region
  smtp_host        = "email-smtp.${local.region}.amazonaws.com"
  from_address     = "${var.from_local_part}@${var.primary_domain}"
  mail_from_domain = "${var.mail_from_subdomain}.${var.primary_domain}"
}

resource "aws_sesv2_email_identity" "this" {
  email_identity = var.primary_domain
}

# Custom MAIL FROM gives SPF alignment under our own domain instead of
# amazonses.com. Reject behaviour means SES fails the send if the MX/SPF
# records are missing rather than silently falling back to the SES default.
resource "aws_sesv2_email_identity_mail_from_attributes" "this" {
  email_identity         = aws_sesv2_email_identity.this.email_identity
  mail_from_domain       = local.mail_from_domain
  behavior_on_mx_failure = "REJECT_MESSAGE"

  depends_on = [aws_route53_record.mail_from_mx, aws_route53_record.mail_from_spf]
}
