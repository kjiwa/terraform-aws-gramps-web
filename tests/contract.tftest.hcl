mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012", arn = "arn:aws:iam::123456789012:user/test" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1", name = "us-east-1" }
  }
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-east-1a", "us-east-1b"] }
  }
  mock_data "aws_route53_zone" {
    defaults = { zone_id = "Z0000000000000TEST" }
  }
  mock_data "aws_ami" {
    defaults = { id = "ami-0123456789abcdef0" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

mock_provider "aws" {
  alias = "us_east_1"
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012", arn = "arn:aws:iam::123456789012:user/test" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1", name = "us-east-1" }
  }
}

override_module {
  target = module.email
  outputs = {
    smtp_host              = "email-smtp.us-east-1.amazonaws.com"
    smtp_username          = "AKIATEST"
    from_address           = "gramps@example.org"
    smtp_password_ssm_path = "/gramps-web/prod/smtp-password"
    smtp_port              = 587
    smtp_use_starttls      = true
  }
}

override_resource {
  target          = module.edge.aws_acm_certificate.this
  override_during = plan
  values = {
    arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"
    domain_validation_options = [
      { domain_name = "example.org", resource_record_name = "_a.example.org.", resource_record_type = "CNAME", resource_record_value = "a.acm.example." },
      { domain_name = "www.example.org", resource_record_name = "_b.example.org.", resource_record_type = "CNAME", resource_record_value = "b.acm.example." },
    ]
  }
}

variables {
  primary_domain = "example.org"
  alert_email    = "ops@example.org"
  repo_url       = "https://github.com/kjiwa/terraform-aws-gramps-web"
  source_branch  = "release-0.9"
}

run "defaults_plan_with_only_the_required_inputs" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  assert {
    condition     = toset(local.domains) == toset(["example.org"]) && length(local.domains) == 1
    error_message = "domains must default to the primary domain alone."
  }
  assert {
    condition     = length(local.redirect_domains) == 0
    error_message = "A single-domain deployment has no redirect domains."
  }
  assert {
    condition     = local.zone_ids["example.org"] == "Z0000000000000TEST" && length(local.zone_ids) == 1
    error_message = "Zone ids must come from the looked-up hosted zones."
  }
  assert {
    condition     = var.gramps.version == "26.10.2"
    error_message = "gramps.version must default to the tested release."
  }
  assert {
    condition     = local.llm_region == "us-east-1" && local.backup_region == "us-east-1"
    error_message = "Without the assistant or off-site backups, every region is the module's own."
  }
  assert {
    condition     = length(aws_sns_topic.bedrock_alerts) == 0
    error_message = "The Bedrock alarm must not exist while the assistant is off."
  }
}

run "domains_extra_entries_redirect_to_the_primary" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    domains = ["example.org", "example.net"]
  }

  assert {
    condition     = local.redirect_domains == toset(["example.net"])
    error_message = "Every domain except the primary must be a redirect domain."
  }
  assert {
    condition     = length(data.aws_route53_zone.this) == 2
    error_message = "Each served domain needs a hosted zone lookup."
  }
}

run "ami_ids_null_looks_up_both_architectures" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  assert {
    condition     = toset(keys(data.aws_ami.base)) == toset(["arm64", "x86_64"])
    error_message = "A null ami_ids must look up one AMI per architecture."
  }
  assert {
    condition     = local.ami_ids["arm64"] == "ami-0123456789abcdef0" && local.ami_ids["x86_64"] == "ami-0123456789abcdef0"
    error_message = "Looked-up AMI ids must feed the compute module."
  }
}

run "ami_ids_pinned_skips_the_lookup" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    ami_ids = { arm64 = "ami-0aaaaaaaaaaaaaaaa", x86_64 = "ami-0bbbbbbbbbbbbbbbb" }
  }

  assert {
    condition     = length(data.aws_ami.base) == 0
    error_message = "Pinned ami_ids must not trigger a lookup."
  }
  assert {
    condition     = local.ami_ids.arm64 == "ami-0aaaaaaaaaaaaaaaa"
    error_message = "Pinned ami_ids must pass through unchanged."
  }
}

run "assistant_region_override_moves_the_bedrock_alarm" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    llm = { enabled = true, region = "us-west-2" }
  }

  assert {
    condition     = local.llm_region == "us-west-2"
    error_message = "llm.region must override the invocation region when the assistant is on."
  }
  assert {
    condition     = aws_cloudwatch_metric_alarm.bedrock_tokens[0].region == "us-west-2" && aws_sns_topic.bedrock_alerts[0].region == "us-west-2"
    error_message = "The Bedrock alarm and its topic must live in the invocation region."
  }
  assert {
    condition     = contains(local.effective_addons, "FilterRules")
    error_message = "The assistant must bake in the FilterRules addon."
  }
}

run "assistant_region_ignored_while_off" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    llm = { region = "us-west-2" }
  }

  assert {
    condition     = local.llm_region == "us-east-1"
    error_message = "llm.region must be ignored while the assistant is off."
  }
}

run "cross_region_backup_defaults_the_destination" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    backup = { mode = "cross_region" }
  }

  assert {
    condition     = local.backup_region == "us-east-2"
    error_message = "cross_region must default the destination to us-east-2."
  }
}

run "status_disabled_panels_follow_the_toggles" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    status = { enabled = true, host_metrics = true }
  }

  assert {
    condition     = !contains(local.status_disabled_panels, "host_metrics") && contains(local.status_disabled_panels, "cost") && contains(local.status_disabled_panels, "assistant")
    error_message = "Only panels whose feature is off may be hidden."
  }
}

run "seam_inputs_reach_the_primary_distribution" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    additional_origins = {
      viewer = { domain_name = "viewer.s3.us-east-1.amazonaws.com" }
    }
    additional_cache_behaviors = [{
      path_pattern     = "/viewer/*"
      target_origin_id = "viewer"
    }]
  }

  assert {
    condition     = length(var.additional_cache_behaviors) == 1 && contains(keys(var.additional_origins), "viewer")
    error_message = "Seam inputs must be accepted with their defaults applied."
  }
  assert {
    condition     = var.additional_cache_behaviors[0].cache_policy_id == "658327ea-f89d-4fab-a63d-7e88639e58f6"
    error_message = "Behaviors must default to the managed CachingOptimized policy."
  }
}

run "alert_email_must_be_an_address" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    alert_email = "not-an-email"
  }
  expect_failures = [var.alert_email]
}

run "domains_must_include_the_primary" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    domains = ["example.net"]
  }
  expect_failures = [var.domains]
}

run "domains_must_be_lowercase" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    primary_domain = "Example.org"
    domains        = ["Example.org"]
  }
  expect_failures = [var.domains]
}

run "domains_must_be_unique" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    domains = ["example.org", "example.org"]
  }
  expect_failures = [var.domains]
}

run "env_must_be_a_short_slug" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    env = "Prod_1"
  }
  expect_failures = [var.env]
}

run "ami_ids_need_both_architectures" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    ami_ids = { arm64 = "ami-0aaaaaaaaaaaaaaaa" }
  }
  expect_failures = [var.ami_ids]
}

run "ami_ids_need_ami_format" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    ami_ids = { arm64 = "nope", x86_64 = "ami-0bbbbbbbbbbbbbbbb" }
  }
  expect_failures = [var.ami_ids]
}

run "data_volume_must_be_a_whole_gib" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    data_volume_gib = 0
  }
  expect_failures = [var.data_volume_gib]
}

run "backup_mode_must_be_known" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    backup = { mode = "sideways" }
  }
  expect_failures = [var.backup]
}

run "backup_cross_account_needs_an_account" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    backup = { mode = "cross_account" }
  }
  expect_failures = [var.backup]
}

run "backup_retention_must_be_positive" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    backup = { retention_days = 0 }
  }
  expect_failures = [var.backup]
}

run "backup_schedule_must_be_an_expression" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    backup = { schedule = "daily" }
  }
  expect_failures = [var.backup]
}

run "monthly_budget_must_be_positive" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    monthly_budget_usd = 0
  }
  expect_failures = [var.monthly_budget_usd]
}

run "spot_strategy_must_be_known" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    spot = { allocation_strategy = "cheapest" }
  }
  expect_failures = [var.spot]
}

run "rightsize_conflicts_with_capacity_aware_spot" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    spot      = { enabled = true }
    rightsize = { schedule = "*-*-* 09:00:00 UTC" }
  }
  expect_failures = [var.rightsize]
}

run "rightsize_uptime_must_be_whole_hours" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    rightsize = { min_uptime_hours = 0 }
  }
  expect_failures = [var.rightsize]
}

run "cpu_credits_must_be_known" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    cpu_credits = "burst"
  }
  expect_failures = [var.cpu_credits]
}

run "repo_url_must_be_github_https" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    repo_url = "git@github.com:you/fork.git"
  }
  expect_failures = [var.repo_url]
}

run "gramps_version_must_be_semver" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    gramps = { version = "latest" }
  }
  expect_failures = [var.gramps]
}

run "gramps_fork_needs_a_ref" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    gramps = { web_repo = "https://github.com/you/gramps-web" }
  }
  expect_failures = [var.gramps]
}

run "gramps_addons_must_be_directory_names" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    gramps = { addons = ["../x"] }
  }
  expect_failures = [var.gramps]
}

run "status_volume_metrics_need_host_metrics" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    status = { volume_metrics = true }
  }
  expect_failures = [var.status]
}

run "status_public_page_excludes_nobody" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    status = { min_role = "nobody", public_reliability = true }
  }
  expect_failures = [var.status]
}

run "status_role_must_be_known" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    status = { min_role = "wizard" }
  }
  expect_failures = [var.status]
}

run "frontend_styles_must_be_urls" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    frontend = { map_ohm_style = "ftp://x" }
  }
  expect_failures = [var.frontend]
}

run "api_tree_needs_an_id" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    api = { tree = "family" }
  }
  expect_failures = [var.api]
}

run "api_cors_rejects_wildcard" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    api = { cors_origins = "*" }
  }
  expect_failures = [var.api]
}

run "api_extra_rejects_secret_keys" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    api = { extra = { DB_PASSWORD = "x" } }
  }
  expect_failures = [var.api]
}

run "api_extra_rejects_derived_keys" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    api = { extra = { TREE = "x" } }
  }
  expect_failures = [var.api]
}

run "api_registration_must_be_known" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    api = { registration = "maybe" }
  }
  expect_failures = [var.api]
}

run "llm_model_must_be_bare" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    llm = { model_id = "bedrock:model" }
  }
  expect_failures = [var.llm]
}

run "llm_limits_must_be_positive" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    llm = { max_tokens = 0 }
  }
  expect_failures = [var.llm]
}

run "outputs_the_operator_scripts_read" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  assert {
    condition = (
      output.env == "prod" && output.region == "us-east-1" &&
      output.primary_domain == "example.org" && output.backup_mode == "local" &&
      output.backup_region == "us-east-1"
    )
    error_message = "env, region, primary_domain, backup_mode, and backup_region must reflect the inputs and defaults."
  }
  assert {
    condition     = output.account_id == "123456789012"
    error_message = "account_id must be the caller's account."
  }
}
