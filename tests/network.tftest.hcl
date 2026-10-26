# Targets modules/network directly with the inputs the root would pass.

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-east-1a", "us-east-1b"] }
  }
}

variables {
  az = "us-east-1a"
}

run "origin_accepts_only_https_from_cloudfront" {
  command = plan
  module {
    source = "./modules/network"
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.origin_https_from_cloudfront.from_port == 443 && aws_vpc_security_group_ingress_rule.origin_https_from_cloudfront.to_port == 443
    error_message = "The origin must accept TCP 443 from the CloudFront prefix list."
  }
}
