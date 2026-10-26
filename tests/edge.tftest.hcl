# Targets modules/edge directly with the inputs the root would pass.

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

mock_provider "aws" {
  alias = "us_east_1"
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

override_resource {
  target          = aws_acm_certificate.this
  override_during = plan
  values = {
    arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
    domain_validation_options = [
      { domain_name = "example.org", resource_record_name = "_a.example.org.", resource_record_type = "CNAME", resource_record_value = "a.acm.example." },
      { domain_name = "www.example.org", resource_record_name = "_b.example.org.", resource_record_type = "CNAME", resource_record_value = "b.acm.example." },
    ]
  }
}

override_resource {
  target          = aws_acm_certificate.origin
  override_during = plan
  values = {
    arn = "arn:aws:acm:us-east-2:123456789012:certificate/11111111-1111-1111-1111-111111111111"
    domain_validation_options = [
      { domain_name = "origin.example.org", resource_record_name = "_o.origin.example.org.", resource_record_type = "CNAME", resource_record_value = "o.acm.example." },
    ]
  }
}

variables {
  env              = "prod"
  primary_domain   = "example.org"
  redirect_domains = []
  eip_public_ip    = "192.0.2.10"
  zone_ids         = { "example.org" = "Z0000000000000TEST" }
}

run "origin_certificate_is_exportable_for_the_origin_host" {
  command = plan
  module {
    source = "./modules/edge"
  }
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  assert {
    condition     = aws_acm_certificate.origin.domain_name == "origin.example.org"
    error_message = "The origin certificate must name origin.<primary_domain>."
  }
  assert {
    condition     = aws_acm_certificate.origin.options[0].export == "ENABLED"
    error_message = "The origin certificate must be exportable; the instance exports it at deploy time."
  }
  assert {
    condition     = aws_acm_certificate.origin.validation_method == "DNS"
    error_message = "The origin certificate must validate over DNS."
  }
  assert {
    condition     = contains(keys(aws_route53_record.cert_validation), "origin.example.org:origin.example.org")
    error_message = "The origin certificate's validation record must be created."
  }
}

run "primary_distribution_reaches_the_origin_over_https" {
  command = plan
  module {
    source = "./modules/edge"
  }
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  assert {
    condition = alltrue([
      for o in aws_cloudfront_distribution.primary.origin :
      o.custom_origin_config[0].origin_protocol_policy == "https-only" if o.origin_id == "ec2-origin"
    ])
    error_message = "The ec2-origin must use https-only."
  }
}

run "redirect_distribution_reaches_the_origin_over_https" {
  command = plan
  module {
    source = "./modules/edge"
  }
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  assert {
    condition = alltrue([
      for d in aws_cloudfront_distribution.redirect : alltrue([
        for o in d.origin : o.custom_origin_config[0].origin_protocol_policy == "https-only" if o.origin_id == "ec2-origin"
      ])
    ])
    error_message = "The redirect distributions' ec2-origin must use https-only."
  }
}
