locals {
  zone_id = var.zone_ids[var.primary_domain]

  dmarc_value = var.dmarc_rua == "" ? "v=DMARC1; p=none;" : "v=DMARC1; p=none; rua=${var.dmarc_rua};"
}

# Easy DKIM: three CNAMEs. These also serve as domain-verification proof, so
# the identity stays unverified (and all sends fail) until they propagate.
resource "aws_route53_record" "dkim" {
  count = 3

  zone_id = local.zone_id
  name    = "${aws_sesv2_email_identity.this.dkim_signing_attributes[0].tokens[count.index]}._domainkey.${var.primary_domain}"
  type    = "CNAME"
  ttl     = 1800
  records = ["${aws_sesv2_email_identity.this.dkim_signing_attributes[0].tokens[count.index]}.dkim.amazonses.com"]
}

# MAIL FROM subdomain: MX so bounces route to SES, TXT (SPF) so receivers
# accept the envelope sender.
resource "aws_route53_record" "mail_from_mx" {
  zone_id = local.zone_id
  name    = local.mail_from_domain
  type    = "MX"
  ttl     = 1800
  records = ["10 feedback-smtp.${local.region}.amazonses.com"]
}

resource "aws_route53_record" "mail_from_spf" {
  zone_id = local.zone_id
  name    = local.mail_from_domain
  type    = "TXT"
  ttl     = 1800
  records = ["v=spf1 include:amazonses.com -all"]
}

resource "aws_route53_record" "dmarc" {
  zone_id = local.zone_id
  name    = "_dmarc.${var.primary_domain}"
  type    = "TXT"
  ttl     = 1800
  records = [local.dmarc_value]
}
