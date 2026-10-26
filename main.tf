module "network" {
  source = "./modules/network"
  az     = local.az
}

module "storage" {
  source = "./modules/storage"

  az                      = local.az
  data_volume_gib         = var.data_volume_gib
  data_volume_snapshot_id = var.data_volume_snapshot_id
  media_bucket_name       = var.media_bucket_name
  backup                  = var.backup
  backup_region           = local.backup_region
}

module "email" {
  source = "./modules/email"

  env            = var.env
  primary_domain = var.primary_domain
  zone_ids       = local.zone_ids
  dmarc_rua      = var.dmarc_rua
}

module "compute" {
  source = "./modules/compute"

  env                        = var.env
  active                     = var.active
  ami_ids                    = local.ami_ids
  subnet_ids                 = module.network.subnet_ids
  origin_sg_id               = module.network.origin_sg_id
  ebs_volume_id              = module.storage.ebs_volume_id
  ebs_volume_arn             = module.storage.ebs_volume_arn
  ebs_kms_key_arn            = module.storage.ebs_kms_key_arn
  media_bucket_name          = module.storage.media_bucket_name
  media_bucket_arn           = module.storage.media_bucket_arn
  spot_enabled               = var.spot.enabled
  spot_allocation_strategy   = var.spot.allocation_strategy
  instance_requirements      = var.instance_requirements
  rightsize_schedule         = var.rightsize.schedule
  rightsize_min_uptime_hours = var.rightsize.min_uptime_hours
  cpu_credits                = var.cpu_credits
  status_host_metrics        = var.status.host_metrics
  status_volume_metrics      = var.status.volume_metrics
  origin_certificate_arn     = module.edge.origin_certificate_arn

  api      = var.api
  frontend = var.frontend
  llm = {
    enabled            = var.llm.enabled
    model_id           = var.llm.model_id
    region             = local.llm_region
    max_requests       = var.llm.max_requests
    max_tokens         = var.llm.max_tokens
    max_context_length = var.llm.max_context_length
    system_prompt      = var.llm.system_prompt
  }

  base_url = "https://${var.primary_domain}"
  smtp = {
    host              = module.email.smtp_host
    username          = module.email.smtp_username
    from_address      = module.email.from_address
    password_ssm_path = module.email.smtp_password_ssm_path
    port              = module.email.smtp_port
    use_starttls      = module.email.smtp_use_starttls
  }

  pathological_refresh_alarm_names = [aws_cloudwatch_metric_alarm.instance_refresh_pathological.alarm_name]
}

module "edge" {
  source = "./modules/edge"
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  env              = var.env
  primary_domain   = var.primary_domain
  redirect_domains = local.redirect_domains
  eip_public_ip    = module.compute.eip_public_ip
  zone_ids         = local.zone_ids

  status_origins   = var.status.enabled ? module.status[0].origins : []
  status_behaviors = var.status.enabled ? module.status[0].behaviors : []

  additional_origins         = var.additional_origins
  additional_cache_behaviors = var.additional_cache_behaviors
}

# Authenticated operational status page at /_status (see the status variable).
# Gated on Gramps Web's own role for the caller's token, so it needs the same
# primary_domain as the app itself. The ECR repository name is derived from the
# URL because compute does not output it bare.
module "status" {
  source = "./modules/status"
  count  = var.status.enabled ? 1 : 0

  primary_domain                   = var.primary_domain
  min_role                         = var.status.min_role
  asg_name                         = module.compute.asg_name
  codedeploy_app_name              = module.compute.codedeploy_app_name
  codedeploy_deployment_group_name = module.compute.codedeploy_deployment_group_name
  deliberate_deployment_creators   = module.compute.deliberate_deployment_creators
  codepipeline_name                = module.app_pipeline.pipeline_name
  source_repo                      = local.source_repo
  ecr_repository_name              = element(split("/", module.compute.ecr_repository_url), 1)
  ecr_repository_arn               = module.compute.ecr_repository_arn
  ebs_volume_id                    = module.storage.ebs_volume_id
  media_bucket_name                = module.storage.media_bucket_name
  backup_vault_name                = module.storage.backup_vault_name != null ? module.storage.backup_vault_name : ""
  backup_mode                      = var.backup.mode
  backup_schedule                  = var.backup.schedule
  backup_retention_days            = var.backup.retention_days
  backup_resource_count            = module.storage.backup_resource_count
  backup_remote_retention_days     = module.storage.backup_remote_retention_days
  backup_region                    = local.backup_region
  backup_copy_vault_arn            = module.storage.backup_copy_vault_arn != null ? module.storage.backup_copy_vault_arn : ""
  backup_dest_reader_role_arn      = local.backup_dest_reader_role_arn
  spot_enabled                     = var.spot.enabled
  llm = {
    enabled            = var.llm.enabled
    model_id           = var.llm.model_id
    region             = local.llm_region
    max_requests       = var.llm.max_requests
    max_tokens         = var.llm.max_tokens
    max_context_length = var.llm.max_context_length
  }
  gramps_web_version     = var.gramps.version
  monthly_budget_usd     = var.monthly_budget_usd
  cost_enabled           = var.status.cost
  host_metrics_enabled   = var.status.host_metrics
  volume_metrics_enabled = var.status.volume_metrics
  public_reliability     = var.status.public_reliability

  distribution_arn             = module.edge.primary_distribution_arn
  episodes_log_group           = module.monitoring.episodes_log_group_name
  spot_interruptions_log_group = module.monitoring.spot_interruptions_log_group_name
  disabled_panels              = local.status_disabled_panels
}

# Shared GitHub CodeConnections app used by the web build, the app
# pipeline, and the AMI build. Created here so there is a single connection to
# approve once (PENDING -> AVAILABLE) in Developer Tools > Settings >
# Connections.
resource "aws_codeconnections_connection" "github" {
  name          = "gramps-web"
  provider_type = "GitHub"
}

# First-party frontend (build/web): the error pages. Unconditional, unlike
# status above: the error pages exist regardless of which optional features
# are on.
module "web_build" {
  source = "./modules/web-build"

  repo_url           = var.repo_url
  source_branch      = var.source_branch
  connection_arn     = aws_codeconnections_connection.github.arn
  site_title         = local.site_title
  status_public_page = var.status.enabled && var.status.public_reliability
  errors_bucket_name = module.edge.errors_bucket_name
  errors_bucket_arn  = module.edge.errors_bucket_arn
  distribution_id    = module.edge.primary_distribution_id
  codebuild_image    = local.codebuild_image
}

module "app_pipeline" {
  source = "./modules/app-pipeline"

  connection_arn     = aws_codeconnections_connection.github.arn
  repo_full_name     = local.source_repo
  source_branch      = var.source_branch
  gramps_web_version = var.gramps.version
  gramps_base_image  = var.gramps.base_image
  gramps_addons      = local.effective_addons
  addons_source_repo = var.gramps.addons_source_repo
  gramps_web_repo    = var.gramps.web_repo
  gramps_web_ref     = var.gramps.web_ref

  ecr_repository_url = module.compute.ecr_repository_url
  ecr_repository_arn = module.compute.ecr_repository_arn

  codedeploy_app_name              = module.compute.codedeploy_app_name
  codedeploy_deployment_group_name = module.compute.codedeploy_deployment_group_name

  # The instance fetches deploy bundles from the pipeline's artifact bucket;
  # the grant lives in app-pipeline (which owns the bucket) attached to this
  # role.
  instance_role_name = module.compute.instance_role_name
  codebuild_image    = local.codebuild_image
}

# Base-AMI patch rebuilds under a scoped role. Manual-trigger:
#   aws codebuild start-build --project-name gramps-web-ami
# then apply to roll out the newest AMIs (or pin ami_ids to hold).
module "ami_build" {
  source = "./modules/ami-build"

  repo_url        = var.repo_url
  source_branch   = var.source_branch
  connection_arn  = aws_codeconnections_connection.github.arn
  region          = local.region
  codebuild_image = local.codebuild_image

  ecr_repository_url = module.compute.ecr_repository_url
  ecr_repository_arn = module.compute.ecr_repository_arn
  gramps_web_version = var.gramps.version
}

module "monitoring" {
  source = "./modules/monitoring"

  active                 = var.active
  primary_domain         = var.primary_domain
  asg_name               = module.compute.asg_name
  alert_email            = var.alert_email
  backup_enabled         = var.backup.mode != "disabled"
  host_metrics_enabled   = var.status.host_metrics
  volume_metrics_enabled = var.status.volume_metrics

  codedeploy_app_name              = module.compute.codedeploy_app_name
  codedeploy_deployment_group_name = module.compute.codedeploy_deployment_group_name
  last_rightsize_param_name        = module.compute.last_rightsize_param_name
  last_rightsize_param_arn         = module.compute.last_rightsize_param_arn
  last_health_watchdog_param_name  = module.compute.last_health_watchdog_param_name
  last_health_watchdog_param_arn   = module.compute.last_health_watchdog_param_arn
  last_backup_snapshot_param_name  = module.compute.last_backup_snapshot_param_name
  last_backup_snapshot_param_arn   = module.compute.last_backup_snapshot_param_arn
  deliberate_deployment_creators   = module.compute.deliberate_deployment_creators
}

# Guards module.compute's instance_refresh (asg.tf), so a refresh whose
# replacement never comes up reports Failed instead of Successful. Lives
# here, not in module.monitoring alongside gramps-web-site-down: monitoring
# already takes module.compute.asg_name as an input, so an alarm that
# module.compute needed back (for alarm_specification) would be a module
# cycle. Same metric as gramps-web-site-down
# (modules/monitoring/alerts.tf), but a much longer window: every normal
# size-1 refresh is down for the 3-5 min a replacement takes to
# boot, so this may not trip before minute 15, only after.
#
# treat_missing_data = "ignore", unlike site_down: this alarm's consumer is
# StartInstanceRefresh, which refuses to start at all while a named alarm is
# ALARM or INSUFFICIENT_DATA. "breaching" would put it in ALARM permanently
# whenever the canary itself isn't running (var.active = false), blocking
# every launch-template apply during sleep, and would keep it ALARM right
# after a real pathological refresh trips it -- refusing the very follow-up
# refresh that would recover. A real 15-minute outage still needs a refresh
# started without this AlarmSpecification, or the instance terminated for the
# ASG to replace directly.
resource "aws_cloudwatch_metric_alarm" "instance_refresh_pathological" {
  alarm_name          = "gramps-web-instance-refresh-pathological"
  alarm_description   = "Instance refresh has left the site down for 15+ minutes; the replacement is stuck, not just booting."
  namespace           = "GrampsWeb"
  metric_name         = "SiteUp"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 15
  datapoints_to_alarm = 15
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "ignore"

  tags = {
    Name = "gramps-web-instance-refresh-pathological"
  }
}

# Account-level Public Access Block: the backstop for the per-bucket PABs set
# throughout this deployment. A bucket created outside Terraform, or one whose own
# PAB is later loosened, still cannot be made public while this is on. One free
# resource; the single highest-leverage S3 exposure control.
resource "aws_s3_account_public_access_block" "this" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Bedrock token-cost tripwire. Created in the invocation region
# (local.llm_region) because AWS/Bedrock metrics publish there and CloudWatch
# alarm actions must target an SNS topic in the alarm's own region. A surprise
# Bedrock bill is closer to a security event than a site outage, so it gets its
# own topic. Gated on the assistant being enabled and the threshold non-zero.
resource "aws_sns_topic" "bedrock_alerts" {
  count  = var.llm.enabled && var.llm.hourly_token_alarm > 0 ? 1 : 0
  region = local.llm_region
  name   = "gramps-web-bedrock-cost"
}

resource "aws_sns_topic_subscription" "bedrock_alerts_email" {
  count     = var.llm.enabled && var.llm.hourly_token_alarm > 0 ? 1 : 0
  region    = local.llm_region
  topic_arn = aws_sns_topic.bedrock_alerts[0].arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Total tokens = input + output via metric math. Billing-based budgets lag
# 8-24h, so they cannot catch a runaway chat loop within the hour.
resource "aws_cloudwatch_metric_alarm" "bedrock_tokens" {
  count  = var.llm.enabled && var.llm.hourly_token_alarm > 0 ? 1 : 0
  region = local.llm_region

  alarm_name          = "gramps-web-bedrock-hourly-tokens"
  alarm_description   = "Bedrock input+output tokens over the last hour exceeded the runaway-cost threshold."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = var.llm.hourly_token_alarm
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.bedrock_alerts[0].arn]

  metric_query {
    id          = "total"
    expression  = "input + output"
    label       = "Total tokens (input+output)"
    return_data = true
  }

  metric_query {
    id = "input"
    metric {
      namespace   = "AWS/Bedrock"
      metric_name = "InputTokenCount"
      stat        = "Sum"
      period      = 3600
    }
  }

  metric_query {
    id = "output"
    metric {
      namespace   = "AWS/Bedrock"
      metric_name = "OutputTokenCount"
      stat        = "Sum"
      period      = 3600
    }
  }
}
