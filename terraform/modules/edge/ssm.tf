# Publishes the primary distribution's ID for the app deploy hook
# (build/app/bundle/scripts/validate_service.sh) to invalidate stale static
# assets after a deploy (see the static-asset cache behaviors in
# cloudfront_primary.tf). Written HERE, under the same /gramps-web/<env>/*
# path the compute module's instance role can already read (its
# SSMParameters statement in compute/iam.tf), rather than passed to the
# compute module as a Terraform variable: this module already takes
# var.eip_public_ip from compute (route53_records.tf, for the origin's A
# record), so a compute variable sourced from this module's own output would
# close the loop into a dependency cycle. Publishing it as data instead of
# wiring it as a module reference sidesteps that entirely -- the instance
# looks the value up at deploy time instead of Terraform baking it into
# instance.env at boot.
resource "aws_ssm_parameter" "cloudfront_distribution_id" {
  name        = "/gramps-web/${var.env}/cloudfront-distribution-id"
  description = "Primary CloudFront distribution ID. Read by validate_service.sh to invalidate stale static assets after a deploy."
  type        = "String"
  value       = aws_cloudfront_distribution.primary.id

  tags = {
    Name = "gramps-web-cloudfront-distribution-id"
  }
}
