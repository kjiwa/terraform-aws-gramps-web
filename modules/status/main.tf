# Gramps Web layer over the status-page core: maps this module's inputs onto
# the core's objects and supplies plugin/plugin.py (role-API auth, release
# facts) and config.js.tpl. The root attaches the origins and behaviors
# outputs to the primary distribution in modules/edge.
module "core" {
  source = "git::https://github.com/kjiwa/terraform-aws-status-page.git//modules/status?ref=v0.1.1"

  name_prefix      = "gramps-web"
  path_prefix      = "/_status"
  bucket_name      = "${replace(var.primary_domain, ".", "-")}-status"
  auth_header      = "X-Gramps-Token"
  distribution_arn = var.distribution_arn
  asg_name         = var.asg_name

  episodes_log_group           = var.episodes_log_group
  spot_interruptions_log_group = var.spot_interruptions_log_group
  siteup_metric_namespace      = "GrampsWeb"

  source_repo         = var.source_repo
  spot_enabled        = var.spot_enabled
  public_reliability  = var.public_reliability
  ebs_volume_id       = var.ebs_volume_id
  storage_bucket_name = var.media_bucket_name

  codedeploy = {
    app_name              = var.codedeploy_app_name
    deployment_group_name = var.codedeploy_deployment_group_name
    pipeline_name         = var.codepipeline_name
    ecr_repository_name   = var.ecr_repository_name
    ecr_repository_arn    = var.ecr_repository_arn
    deliberate_creators   = var.deliberate_deployment_creators
  }

  backup = var.backup_vault_name == "" ? null : {
    vault_name            = var.backup_vault_name
    mode                  = var.backup_mode
    schedule              = var.backup_schedule
    retention_days        = var.backup_retention_days
    resource_count        = var.backup_resource_count
    remote_retention_days = var.backup_remote_retention_days
    region                = var.backup_region
    copy_vault_arn        = var.backup_copy_vault_arn
    dest_reader_role_arn  = var.backup_dest_reader_role_arn
  }

  bedrock = var.llm.enabled ? {
    region             = var.llm.region
    model_id           = var.llm.model_id
    max_requests       = var.llm.max_requests
    max_tokens         = var.llm.max_tokens
    max_context_length = var.llm.max_context_length
  } : null

  cost         = var.cost_enabled ? { monthly_budget_usd = var.monthly_budget_usd } : null
  host_metrics = var.host_metrics_enabled ? { volume_metrics = var.volume_metrics_enabled } : null

  plugin_dir = "${path.module}/plugin"
  plugin_environment = {
    SITE_URL           = "https://${var.primary_domain}"
    MIN_ROLE           = var.min_role
    GRAMPS_WEB_VERSION = var.gramps_web_version
  }

  config_js = templatefile("${path.module}/config.js.tpl", { disabled = var.disabled_panels })
}
