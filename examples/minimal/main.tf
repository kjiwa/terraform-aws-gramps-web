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

  # The module looks up the hosted zone by name, so it must exist first.
  depends_on = [module.dns]
}

module "audit" {
  source = "git::https://github.com/kjiwa/terraform-aws-keel.git//modules/audit?ref=v0.1.0"

  name_prefix = "gramps-web"
  alert_email = var.alert_email
  log_source_buckets = [{
    name = module.gramps_web.media_bucket_name
    arn  = module.gramps_web.media_bucket_arn
  }]
}
