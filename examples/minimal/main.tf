data "aws_caller_identity" "current" {}

locals {
  # Named here, not read from the module: audit keys a for_each by bucket name,
  # which must be known at plan time.
  media_bucket_name = "gramps-web-media-${data.aws_caller_identity.current.account_id}"
}

module "dns" {
  source = "git::https://github.com/kjiwa/terraform-aws-keel.git//modules/dns?ref=v0.1.0"
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  name_prefix = "gramps-web"
  domains     = { (var.primary_domain) = {} }
}

module "finops" {
  source = "git::https://github.com/kjiwa/terraform-aws-keel.git//modules/finops?ref=v0.1.0"
  providers = {
    aws = aws.us_east_1
  }

  name_prefix = "gramps-web"
  alert_email = var.alert_email
}

module "gramps_web" {
  source = "../.."
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  primary_domain = var.primary_domain
  alert_email    = var.alert_email
  repo_url       = var.repo_url
  source_branch  = var.source_branch

  media_bucket_name = local.media_bucket_name

  # The module looks up the hosted zone by name, so it must exist first.
  depends_on = [module.dns]
}

module "audit" {
  source = "git::https://github.com/kjiwa/terraform-aws-keel.git//modules/audit?ref=v0.1.0"

  name_prefix        = "gramps-web"
  alert_email        = var.alert_email
  log_retention_days = var.audit_log_retention_days
  log_source_buckets = [{
    name = local.media_bucket_name
    arn  = "arn:aws:s3:::${local.media_bucket_name}"
  }]
}
